"""
Cold chain device simulator.

Publishes telemetry to AWS IoT Core via MQTT over mutual TLS (port 8883)
using X.509 client certificate authentication.

Usage:
  See simulator/README.md for the full setup sequence including certificate
  provisioning. Quick start once certs are in place:

    export IOT_ENDPOINT="<endpoint>.iot.<region>.amazonaws.com"
    export CERT_PATH="certs/device.pem.crt"
    export KEY_PATH="certs/private.pem.key"
    export CA_PATH="certs/AmazonRootCA1.pem"
    export DEVICE_ID="cold-chain-sim-01"
    python device_simulator.py

Optional environment variables:
    FLEET_ID               Fleet/shipment group identifier (optional)
    FIRMWARE_VERSION       Firmware version string (optional, default: 2.1.0)
    PUBLISH_INTERVAL_S     Seconds between publishes (default: 10)
    DOMAIN                 MQTT topic domain segment (default: coldchain)
    LOG_LEVEL              DEBUG | INFO | WARNING (default: INFO)

Authentication:
  Mutual TLS — the device authenticates the broker via the Amazon Root CA,
  and the broker authenticates the device via its X.509 client certificate.
  No username/password, no API key. See README.md: "Why X.509 over API keys."
"""

import json
import logging
import os
import signal
import sys
import time
from typing import Optional

import paho.mqtt.client as mqtt

from payload_generator import SimulatorState, generate_payload

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

IOT_ENDPOINT = os.environ.get("IOT_ENDPOINT", "")
CERT_PATH = os.environ.get("CERT_PATH", "certs/device.pem.crt")
KEY_PATH = os.environ.get("KEY_PATH", "certs/private.pem.key")
CA_PATH = os.environ.get("CA_PATH", "certs/AmazonRootCA1.pem")
DEVICE_ID = os.environ.get("DEVICE_ID", "cold-chain-sim-01")
FLEET_ID = os.environ.get("FLEET_ID", None)
FIRMWARE_VERSION = os.environ.get("FIRMWARE_VERSION", "2.1.0")
PUBLISH_INTERVAL_S = int(os.environ.get("PUBLISH_INTERVAL_S", "10"))
DOMAIN = os.environ.get("DOMAIN", "coldchain")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()

MQTT_PORT = 8883
TOPIC = f"dt/{DOMAIN}/{DEVICE_ID}/telemetry"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# MQTT callbacks
# ---------------------------------------------------------------------------

def on_connect(client: mqtt.Client, userdata: dict, flags: dict, rc: int) -> None:
    if rc == 0:
        logger.info(f"Connected to IoT Core — {DEVICE_ID}")
        userdata["connected"] = True
    else:
        # paho rc codes: 1=bad protocol, 2=bad client id, 3=server unavailable,
        # 4=bad credentials, 5=not authorized
        rc_messages = {
            1: "bad protocol version",
            2: "bad client ID (must match Thing name)",
            3: "server unavailable",
            4: "bad credentials (cert/key issue)",
            5: "not authorized (IoT policy check failed)",
        }
        logger.error(
            f"Connection failed: rc={rc} — {rc_messages.get(rc, 'unknown error')}"
        )
        userdata["connected"] = False


def on_disconnect(client: mqtt.Client, userdata: dict, rc: int) -> None:
    if rc == 0:
        logger.info("Disconnected cleanly.")
    else:
        logger.warning(f"Unexpected disconnect: rc={rc}. Will attempt reconnect.")
        userdata["connected"] = False


def on_publish(client: mqtt.Client, userdata: dict, mid: int) -> None:
    logger.debug(f"Message {mid} acknowledged by broker.")


# ---------------------------------------------------------------------------
# Simulator loop
# ---------------------------------------------------------------------------

def validate_config() -> None:
    """Fail fast on missing required configuration."""
    missing = []
    if not IOT_ENDPOINT:
        missing.append("IOT_ENDPOINT")
    for path, env_var in [(CERT_PATH, "CERT_PATH"), (KEY_PATH, "KEY_PATH"), (CA_PATH, "CA_PATH")]:
        import os.path
        if not os.path.exists(path):
            missing.append(f"{env_var} (file not found: {path})")
    if missing:
        logger.error("Missing required configuration:")
        for m in missing:
            logger.error(f"  {m}")
        sys.exit(1)


def build_client() -> mqtt.Client:
    """
    Configure the MQTT client with mutual TLS.

    Client ID = DEVICE_ID. The IoT policy in iot_thing/main.tf enforces
    that the client ID matches the Thing name via the iot:ClientId condition.
    Using any other client ID will result in a policy denial (rc=5).
    """
    userdata = {"connected": False}

    client = mqtt.Client(
        client_id=DEVICE_ID,
        protocol=mqtt.MQTTv311,
        userdata=userdata,
    )

    # Mutual TLS — broker cert (CA) + device cert + device private key
    client.tls_set(
        ca_certs=CA_PATH,
        certfile=CERT_PATH,
        keyfile=KEY_PATH,
    )

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_publish = on_publish

    # Keep-alive: 60 seconds. IoT Core will detect a dead connection within
    # 1.5x the keep-alive interval (90s) and send a LWT if configured.
    client.connect(IOT_ENDPOINT, MQTT_PORT, keepalive=60)

    return client


def run() -> None:
    validate_config()

    logger.info(f"Starting simulator: device={DEVICE_ID}, topic={TOPIC}, interval={PUBLISH_INTERVAL_S}s")
    logger.info(f"IoT endpoint: {IOT_ENDPOINT}")

    client = build_client()
    state = SimulatorState()

    # Graceful shutdown on SIGINT / SIGTERM
    shutdown = {"requested": False}

    def _shutdown(signum, frame):
        logger.info("Shutdown requested.")
        shutdown["requested"] = True

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    client.loop_start()

    # Brief pause to allow the connect callback to fire
    time.sleep(2)

    if not client._userdata["connected"]:
        logger.error("Failed to connect. Check endpoint, certificates, and IoT policy.")
        client.loop_stop()
        sys.exit(1)

    while not shutdown["requested"]:
        payload = generate_payload(
            device_id=DEVICE_ID,
            state=state,
            fleet_id=FLEET_ID,
            firmware_version=FIRMWARE_VERSION,
        )

        payload_json = json.dumps(payload)

        result = client.publish(
            topic=TOPIC,
            payload=payload_json,
            qos=1,  # At-least-once delivery. The Lambda processor handles duplicates.
        )

        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            logger.info(
                f"Published → {TOPIC} | "
                f"temp: {payload['temperature_c']}°C, "
                f"hum: {payload['humidity_pct']}%, "
                f"shock: {payload['shock_g']}g, "
                f"bat: {payload['battery_pct']}%"
            )
        else:
            logger.warning(f"Publish failed: rc={result.rc}")

        time.sleep(PUBLISH_INTERVAL_S)

    logger.info("Stopping.")
    client.loop_stop()
    client.disconnect()


if __name__ == "__main__":
    run()
