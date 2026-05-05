# Deployment guide

End-to-end instructions for deploying the stack, running the simulator, triggering and verifying all observable events, and tearing everything down cleanly. This guide reflects a real deployment to AWS — every step was validated.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Python | 3.11+ | Check: `python3 --version` |
| Terraform | ≥ 1.6 | Check: `terraform version` |
| AWS CLI | v2 | Check: `aws --version` |
| AWS credentials | — | Run `aws configure` if not set |

---

## 1. Clone and bootstrap

```bash
git clone https://github.com/jward-adheretech/aws-iot-edge-reference.git
cd aws-iot-edge-reference
chmod +x setup.sh && ./setup.sh
```

`setup.sh` creates two virtual environments and initialises Terraform:

- `simulator/.venv` — paho-mqtt for the device simulator
- `lambda/.venv` — boto3 for local Lambda development
- `terraform/terraform.tfvars` — copied from the example file, ready to edit

---

## 2. Provision device certificates

Certificates are pre-provisioned before `terraform apply`. Terraform manages the association between certificate, Thing, and policy — not the certificate lifecycle itself. This keeps private key material out of Terraform state.

```bash
cd ~/path/to/aws-iot-edge-reference

REGION="us-west-2"       # set to your target region
DEVICE_ID="cold-chain-sim-01"

# Create and register the certificate in IoT Core
CERT_ARN=$(aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile simulator/certs/device.pem.crt \
  --public-key-outfile simulator/certs/public.pem.key \
  --private-key-outfile simulator/certs/private.pem.key \
  --region $REGION \
  --query 'certificateArn' \
  --output text)

echo "Certificate ARN: $CERT_ARN"

# Download the Amazon Root CA (broker authentication)
curl -o simulator/certs/AmazonRootCA1.pem \
  https://www.amazontrust.com/repository/AmazonRootCA1.pem
```

Note the certificate ARN — you need it in the next step.

See `simulator/certs/README.md` for the full provisioning reference including revocation and cleanup.

---

## 3. Configure terraform.tfvars

`setup.sh` created `terraform/terraform.tfvars` from the example. Edit it:

```hcl
aws_region  = "us-west-2"
project     = "iot-coldchain"
environment = "dev"
domain      = "coldchain"

device_ids = [
  "cold-chain-sim-01",
]

certificate_arns = {
  "cold-chain-sim-01" = "arn:aws:iot:us-west-2:YOUR_ACCOUNT_ID:cert/YOUR_CERT_ID"
}

temp_excursion_threshold_c = 8.0
battery_low_threshold_pct  = 15
device_silence_minutes     = 5
telemetry_ttl_days         = 90

alert_email = "your@email.com"   # leave empty to skip SNS email subscription

lambda_log_retention_days   = 30
lambda_reserved_concurrency = -1
```

**Important:** After `terraform apply`, AWS sends a subscription confirmation email to `alert_email`. Click the confirm link or alarm notifications will not be delivered.

---

## 4. Deploy

```bash
cd terraform
terraform plan    # review before applying
terraform apply   # type 'yes' when prompted
```

Deployment takes 60–90 seconds. On completion, Terraform prints the outputs you need for the next steps:

```
cloudwatch_dashboard_url = "https://us-west-2.console.aws.amazon.com/..."
dynamodb_table_name      = "iot-coldchain-dev-telemetry"
iot_endpoint             = "xxxxxxxxxxxx-ats.iot.us-west-2.amazonaws.com"
lambda_function_name     = "iot-coldchain-dev-telemetry-processor"
registered_things        = { "cold-chain-sim-01" = "arn:aws:iot:..." }
sns_alerts_topic_arn     = "arn:aws:sns:us-west-2:..."
```

---

## 5. Run the simulator

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

Expected output when connected and publishing:

```
[2026-05-04 17:10:13] INFO Connected to IoT Core — cold-chain-sim-01
[2026-05-04 17:10:13] INFO Published → dt/coldchain/cold-chain-sim-01/telemetry | temp: 3.09°C, hum: 64.7%, shock: 0.02g, bat: 100.0%
[2026-05-04 17:10:23] INFO Published → dt/coldchain/cold-chain-sim-01/telemetry | temp: 3.0°C, hum: 64.5%, shock: 0.009g, bat: 100.0%
```

The simulator publishes every 10 seconds. Temperature holds near the 2–4°C setpoint under normal operation.

---

## 6. Verify the pipeline

### IoT Core — confirm messages are arriving

In the AWS Console: **IoT Core → Test → MQTT test client → Subscribe to a topic**

Subscribe to:
```
dt/coldchain/cold-chain-sim-01/telemetry
```

You should see JSON payloads arriving every 10 seconds.

### DynamoDB — confirm Lambda is writing records

```bash
aws dynamodb scan \
  --table-name iot-coldchain-dev-telemetry \
  --region us-west-2 \
  --max-items 3
```

Each item should contain all telemetry fields plus `ingested_at` (added by Lambda) and `expires_at` (the computed TTL epoch timestamp).

### CloudWatch Logs — confirm structured events

In the AWS Console: **CloudWatch → Log groups → `/aws/lambda/iot-coldchain-dev-telemetry-processor`**

Open the most recent log stream. You should see JSON log lines with `"event_type": "TELEMETRY_INGESTED"`:

```json
{
    "event_type": "TELEMETRY_INGESTED",
    "ingested_at": "2026-05-05T00:07:20.522371+00:00",
    "device_id": "cold-chain-sim-01",
    "timestamp": "2026-05-05T00:07:19Z",
    "temperature_c": 3.05,
    "humidity_pct": 65.0,
    "shock_g": 0.01,
    "battery_pct": 100.0,
    "fleet_id": null
}
```

### CloudWatch Metrics — confirm metric filters are working

In the AWS Console: **CloudWatch → Metrics → All metrics → Custom namespaces → ColdChain/dev**

Three metrics should appear:
- `TelemetryIngestedCount`
- `TemperatureExcursionCount`
- `BatteryLowCount`

`TelemetryIngestedCount` will have data points immediately. The excursion metrics populate after you trigger a test event (see next section).

### CloudWatch Dashboard

Open the dashboard URL from `terraform output`. The **Telemetry Ingest Rate** widget should show a non-zero line. Other widgets populate after excursion events are triggered.

> **Note:** Custom metric widgets can take 2–5 minutes to show data after the first event, as CloudWatch processes the metric filter matches.

---

## 7. Trigger a temperature excursion event

The simulator models realistic cold chain conditions — temperature holds near setpoint under normal operation and rarely crosses the 8°C excursion threshold organically. Use this procedure to trigger a verifiable excursion event on demand.

Stop the simulator (Ctrl+C), then publish a single out-of-range payload:

```bash
cd simulator
source .venv/bin/activate   # if not already active

python3 - << 'EOF'
import paho.mqtt.client as mqtt
import json, os, time

IOT_ENDPOINT = os.environ["IOT_ENDPOINT"]
DEVICE_ID    = os.environ.get("DEVICE_ID", "cold-chain-sim-01")

client = mqtt.Client(client_id=DEVICE_ID, protocol=mqtt.MQTTv311)
client.tls_set(
    ca_certs="certs/AmazonRootCA1.pem",
    certfile="certs/device.pem.crt",
    keyfile="certs/private.pem.key",
)
client.connect(IOT_ENDPOINT, 8883, keepalive=60)
client.loop_start()
time.sleep(2)

payload = {
    "device_id": DEVICE_ID,
    "timestamp": "2026-05-04T18:00:00Z",
    "latitude":  47.6062,
    "longitude": -122.3321,
    "temperature_c": 12.5,       # above 8.0°C threshold
    "humidity_pct":  78.0,
    "shock_g":       0.01,
    "battery_pct":   95.0,
}

topic = f"dt/coldchain/{DEVICE_ID}/telemetry"
client.publish(topic, json.dumps(payload), qos=1)
print(f"Excursion payload sent → {topic}")
print(f"temperature_c: {payload['temperature_c']}°C (threshold: 8.0°C)")
time.sleep(2)
client.loop_stop()
client.disconnect()
EOF
```

### Verify the excursion event

In **CloudWatch → Log groups → `/aws/lambda/iot-coldchain-dev-telemetry-processor`**, open the most recent log stream. Within 30 seconds you should see:

```json
{
    "event_type": "TEMPERATURE_EXCURSION",
    "ingested_at": "2026-05-05T01:00:38.833130+00:00",
    "device_id": "cold-chain-sim-01",
    "timestamp": "2026-05-04T18:00:00Z",
    "temperature_c": 12.5,
    "threshold_c": 8.0,
    "latitude": 47.6062,
    "longitude": -122.3321,
    "fleet_id": null
}
```

Note that `threshold_c` is logged alongside `temperature_c` — an on-call engineer reading the log can assess severity without looking up the configuration.

The `TemperatureExcursionCount` metric in **CloudWatch → Metrics → ColdChain/dev** should show a data point. The `TemperatureExcursion` alarm fires after 2 consecutive evaluation periods with excursion events — a single test payload puts the alarm into `INSUFFICIENT_DATA` or `ALARM` state depending on timing.

---

## 8. Tear down

```bash
cd terraform
terraform destroy   # type 'yes' when prompted
```

Terraform removes all managed resources. Verify in the AWS Console that the following are gone:

- IoT Core: Thing `cold-chain-sim-01`, policy `iot-coldchain-dev-device-cold-chain-sim-01`
- Lambda: `iot-coldchain-dev-telemetry-processor`
- DynamoDB: `iot-coldchain-dev-telemetry`
- CloudWatch: dashboard `iot-coldchain-dev-operations`, log groups, alarms
- SQS: `iot-coldchain-dev-processor-dlq`
- SNS: `iot-coldchain-dev-alerts`

### Clean up the certificate

The X.509 certificate was provisioned outside Terraform and must be removed manually:

```bash
CERT_ID="YOUR_CERTIFICATE_ID"   # the hex string after 'cert/' in the ARN
REGION="us-west-2"

aws iot update-certificate \
  --certificate-id $CERT_ID \
  --new-status INACTIVE \
  --region $REGION

aws iot delete-certificate \
  --certificate-id $CERT_ID \
  --region $REGION
```

### Clean up local certificate files

```bash
rm simulator/certs/device.pem.crt \
   simulator/certs/private.pem.key \
   simulator/certs/public.pem.key \
   simulator/certs/AmazonRootCA1.pem
```

These files are `.gitignored` and will not appear in `git status`, but remove them explicitly after a deployment cycle.

---

## Cost estimate

Running this stack for a short evaluation is near-free:

| Service | Free tier | Typical test cost |
|---------|-----------|-------------------|
| IoT Core | 500K messages/month | < $0.01 |
| Lambda | 1M invocations/month | < $0.01 |
| DynamoDB | 25GB storage, 25 WCU | < $0.01 |
| CloudWatch | 10 metrics, 10 alarms | < $0.10 |
| SQS | 1M requests/month | $0.00 |
| SNS | 1M publishes/month | $0.00 |

A typical test session (1–2 hours of simulator publishing at 10-second intervals) costs well under $1.00. Run `terraform destroy` when done.
