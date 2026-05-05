# Device simulator

A Python MQTT device simulator for the cold chain reference implementation. Publishes realistic sensor telemetry to AWS IoT Core via MQTT over mutual TLS using X.509 client certificate authentication.

---

## What it simulates

A refrigerated cargo sensor in transit on a fixed route (Portland, OR → Seattle, WA). The simulator models realistic cold chain conditions:

| Sensor | Behaviour |
|--------|-----------|
| Temperature | Mean-reverting around 3°C setpoint; occasional drift events push toward excursion threshold |
| Humidity | Correlated with temperature — rises during drift events |
| Shock | Near-zero baseline with random spikes simulating road events |
| Battery | Monotonic drain at ~1.2%/hour |
| GPS | Linear interpolation along route with small jitter |

Temperature excursions (sustained readings above 8°C) occur organically during drift events. Use the manual excursion procedure in [`docs/deployment.md`](../docs/deployment.md#7-trigger-a-temperature-excursion-event) to trigger one on demand.

---

## Prerequisites

- Python 3.11+
- Active deployment — run `terraform apply` in `terraform/` first
- Device certificates provisioned — see [`certs/README.md`](certs/README.md)

---

## Setup

```bash
cd simulator
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Or run `setup.sh` from the repo root — it creates this venv automatically.

---

## Configuration

All configuration is via environment variables. No config files, no hardcoded values.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `IOT_ENDPOINT` | Yes | — | AWS IoT Core data endpoint. Get from `terraform output iot_endpoint` |
| `CERT_PATH` | Yes | `certs/device.pem.crt` | Path to device certificate |
| `KEY_PATH` | Yes | `certs/private.pem.key` | Path to device private key |
| `CA_PATH` | Yes | `certs/AmazonRootCA1.pem` | Path to Amazon Root CA |
| `DEVICE_ID` | Yes | `cold-chain-sim-01` | Device ID — must match the IoT Thing name |
| `FLEET_ID` | No | — | Fleet/shipment group identifier |
| `FIRMWARE_VERSION` | No | `2.1.0` | Firmware version string |
| `PUBLISH_INTERVAL_S` | No | `10` | Seconds between publishes |
| `DOMAIN` | No | `coldchain` | MQTT topic domain segment |
| `LOG_LEVEL` | No | `INFO` | `DEBUG`, `INFO`, or `WARNING` |

---

## Run

```bash
cd simulator
source .venv/bin/activate

export IOT_ENDPOINT=$(cd ../terraform && terraform output -raw iot_endpoint)
export CERT_PATH="certs/device.pem.crt"
export KEY_PATH="certs/private.pem.key"
export CA_PATH="certs/AmazonRootCA1.pem"
export DEVICE_ID="cold-chain-sim-01"

python device_simulator.py
```

Expected output:

```
[2026-05-04 17:10:13] INFO Connected to IoT Core — cold-chain-sim-01
[2026-05-04 17:10:13] INFO Published → dt/coldchain/cold-chain-sim-01/telemetry | temp: 3.09°C, hum: 64.7%, shock: 0.02g, bat: 100.0%
[2026-05-04 17:10:23] INFO Published → dt/coldchain/cold-chain-sim-01/telemetry | temp: 3.0°C, hum: 64.5%, shock: 0.009g, bat: 100.0%
```

Stop with `Ctrl+C` — the simulator disconnects cleanly.

---

## Telemetry payload

Each publish sends a JSON payload to `dt/coldchain/{device_id}/telemetry`:

```json
{
    "device_id":        "cold-chain-sim-01",
    "timestamp":        "2026-05-04T17:10:13Z",
    "latitude":         47.2541,
    "longitude":        -122.4413,
    "temperature_c":    3.09,
    "humidity_pct":     64.7,
    "shock_g":          0.02,
    "battery_pct":      100.0,
    "fleet_id":         null,
    "firmware_version": "2.1.0"
}
```

The schema is validated by the Lambda processor against `lambda/processor/models.py`. Any payload that fails validation is logged as `PAYLOAD_INVALID` and dropped — not retried.

---

## Authentication

The simulator uses mutual TLS on port 8883:

- **Broker authentication:** the simulator verifies the IoT Core broker against `AmazonRootCA1.pem`
- **Device authentication:** IoT Core verifies the device against its registered X.509 certificate

The MQTT client ID is set to `DEVICE_ID`. The IoT policy enforces that the client ID matches the Thing name — connecting with a mismatched client ID results in a policy denial (connection refused, rc=5).

See [`certs/README.md`](certs/README.md) for the certificate provisioning sequence and revocation procedure.

---

## Files

| File | Description |
|------|-------------|
| `device_simulator.py` | MQTT client, TLS configuration, publish loop, graceful shutdown |
| `payload_generator.py` | Telemetry simulation model — temperature drift, shock events, GPS interpolation |
| `requirements.txt` | Runtime dependencies (`paho-mqtt`) |
| `certs/` | Certificate directory — `.gitignored`, never committed |
| `certs/README.md` | Certificate provisioning and revocation instructions |
