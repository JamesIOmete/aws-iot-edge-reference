# Architecture extension patterns

This document describes the next layer of a production cold chain platform beyond what is implemented in this reference. Each pattern is described at a design level — the infrastructure in this repo was deliberately structured to accommodate these extensions without rework.

None of these patterns are implemented in the current iteration. They are documented here to show how the reference architecture evolves toward production scale.

---

## OTA firmware updates

### Problem

A fleet of deployed sensors needs firmware updates delivered reliably — new features, bug fixes, security patches. The update mechanism must handle intermittent connectivity, support partial fleet rollouts, and provide a safe rollback path if an update fails.

### Design

AWS IoT Jobs is the right delivery mechanism at fleet scale. The pattern:

**1. Artifact storage**

New firmware is uploaded to S3 with a versioned prefix:
```
s3://your-ota-bucket/firmware/cold-chain-sensor/v2.1.4/firmware.bin
s3://your-ota-bucket/firmware/cold-chain-sensor/v2.1.4/firmware.bin.sha256
```

**2. Job targeting**

An IoT Job is created targeting a Thing Group filtered by firmware version:
```json
{
  "targets": ["arn:aws:iot:us-west-2:ACCOUNT_ID:thinggroup/firmware-lt-2.1.4"],
  "document": {
    "operation": "firmware-update",
    "firmware_version": "2.1.4",
    "download_url": "<pre-signed-s3-url>",
    "checksum_sha256": "abc123...",
    "checksum_url": "<pre-signed-s3-url-for-checksum>",
    "rollback_version": "2.1.3"
  }
}
```

**3. Device-side flow**

The device receives the job document via `$aws/things/{thing_name}/jobs/notify`, downloads the firmware from the pre-signed S3 URL, verifies the SHA-256 checksum, applies the update, and reports success or failure via the job execution update API.

**4. Fleet convergence tracking**

Device Shadow tracks convergence:
```json
{
  "desired":  { "firmware_version": "2.1.4" },
  "reported": { "firmware_version": "2.1.3" }
}
```

A delta between `desired` and `reported` indicates a device that has not yet completed the update. This is queryable across the fleet without a separate database.

### Why pre-signed S3 URLs rather than MQTT transfer

Binary firmware is large (tens to hundreds of KB). MQTT is optimised for small telemetry payloads — publishing firmware over MQTT is wasteful and unreliable over intermittent links. S3 HTTP transfers are resumable, independently retryable, and do not consume MQTT broker capacity.

Pre-signed URLs expire — the device must complete the download within the validity window. This enforces that only currently-provisioned devices with valid certificates can pull firmware, since generating a pre-signed URL requires calling the S3 API with valid AWS credentials.

### Rollback strategy

The job document includes `rollback_version`. If the device reports a failure execution status, it reverts to `rollback_version`, which must already be installed and validated on the device. The job execution status propagates back to the IoT Jobs service, which marks the device as failed and excludes it from the next rollout group.

### What this repo's structure already supports

- Thing attributes include `firmware_version`, making Thing Groups filterable by firmware version without a separate database
- The `modules/iot_thing` module provisions Things with consistent attribute schemas, enabling fleet-wide targeting from day one
- Device Shadow permissions are already included in the per-device IoT policy (commented as extension pattern)

---

## Bi-directional commands

### Problem

The platform needs to send commands to devices — configuration changes, on-demand sensor reads, self-test triggers — and receive acknowledgment that the command was executed.

### Design

**Topic structure:**
```
cmd/{device_id}/request    # cloud → device
cmd/{device_id}/response   # device → cloud
```

Both namespaces are already permitted in the per-device IoT policy in `modules/iot_thing/main.tf`.

**Command document:**
```json
{
  "command_id": "550e8400-e29b-41d4-a716-446655440000",
  "command":    "set_reporting_interval",
  "params":     { "interval_seconds": 30 },
  "issued_at":  "2026-05-04T18:00:00Z",
  "expires_at": "2026-05-04T18:05:00Z"
}
```

**Acknowledgment document (device → cloud):**
```json
{
  "command_id": "550e8400-e29b-41d4-a716-446655440000",
  "status":     "success",
  "executed_at": "2026-05-04T18:00:02Z"
}
```

### Key design considerations

**Idempotency:** Commands carry a `command_id` (UUID). The device deduplicates on `command_id` — receiving the same command twice produces the same outcome, not a double action. This is critical given QoS 1 at-least-once delivery semantics.

**Expiry:** Commands include `expires_at`. If the device reconnects and receives a command that has already expired, it discards the command and sends a `expired` status acknowledgment. This prevents stale commands from executing on a device that was offline during a configuration change window.

**Acknowledgment timeout:** A Lambda function subscribes to `cmd/+/response` via an IoT topic rule. If no acknowledgment arrives within a configurable timeout (typically 60–300 seconds depending on the command), the command is marked `timeout` in DynamoDB and can be retried or escalated via SNS.

**Shadow vs. direct message:** Use Device Shadow for state that must survive a device reconnect — set-point changes, configuration parameters. Use direct MQTT messages for transient commands — take a snapshot, run a self-test. The distinction matters: Shadow state persists in the broker and is delivered to the device on reconnect; direct messages are not queued for offline devices by default (QoS 0) or are queued up to the session expiry (QoS 1 with persistent session).

### What changes at scale

A single `cmd/+/response` topic rule routing to a Lambda function works well up to ~1,000 concurrent devices. Beyond that, consider partitioning the response handler by fleet or device type, or routing to Kinesis for fan-out processing.

---

## Fleet management integration

### Problem

At fleet scale — hundreds to thousands of devices — you need to query device state, manage deployments, and investigate incidents across the fleet without touching each device individually.

### Design

[`platformctl`](https://github.com/jward-adheretech/platformctl) is a fleet management CLI designed to operate against a device registry structured like this repo's. The integration surface:

**Thing naming convention:**
```
{fleet_id}-{device_type}-{serial}
# e.g. fleet-a-cold-chain-001
```

This convention makes `platformctl` queries efficient — filter by fleet or device type without a separate index, using the IoT Core `ListThings` API with attribute filters.

**Thing attributes as queryable metadata:**

Thing attributes in this repo include `device_type` and `managed_by`. A production extension adds:
```json
{
  "device_type":        "cold-chain-sensor",
  "firmware_version":   "2.1.4",
  "hardware_revision":  "rev-b",
  "deployment_region":  "us-west-2",
  "fleet_id":           "fleet-a",
  "managed_by":         "terraform"
}
```

These are queryable via `aws iot list-things --attribute-name firmware_version --attribute-value 2.1.3` — no separate database required for fleet-wide queries at moderate scale.

**Structured log events as the operational data plane:**

The Lambda processor emits `fleet_id` in every structured log event. CloudWatch Logs Insights queries can aggregate across a fleet without a metadata join:

```
fields device_id, temperature_c, fleet_id
| filter fleet_id = "fleet-a" and event_type = "TEMPERATURE_EXCURSION"
| sort ingested_at desc
| limit 20
```

### Scale inflection point

At 10,000+ devices, the `ListThings` API rate limits become a constraint (250 TPS maximum). The right answer at that scale is a dedicated device registry — DynamoDB or Aurora — with IoT Core serving as the authentication and message plane only. The Thing Registry becomes a certificate store; device metadata lives in the application-layer registry.

This repo's structure is designed for that migration: Thing attributes are the source of truth now, and the Lambda processor already writes `fleet_id` and `firmware_version` to DynamoDB telemetry records. Promoting those fields into a dedicated registry table is an additive change, not a refactor.

### Operational runbooks

At fleet scale, operational runbooks become as important as the architecture. Example runbooks that `platformctl` is designed to support:

| Runbook | Query pattern |
|---------|--------------|
| Which devices in fleet-a have not reported in 10 minutes? | DynamoDB: scan last `ingested_at` per device, filter by fleet_id |
| Which devices are still on firmware < 2.1.4? | IoT Core: ListThings with attribute filter |
| What was the temperature profile for device X during shipment Y? | DynamoDB: Query(pk=device_id, sk BETWEEN start AND end) |
| Which devices triggered excursion alarms in the last 24 hours? | CloudWatch Logs Insights: filter event_type = TEMPERATURE_EXCURSION |
