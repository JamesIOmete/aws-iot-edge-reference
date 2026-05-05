"""
Telemetry processor — AWS Lambda handler.

Invoked by the IoT Core rules engine on every message published to:
  dt/coldchain/+/telemetry

Responsibilities:
  1. Validate the inbound payload against the TelemetryPayload schema
  2. Detect threshold excursions and emit structured log events
  3. Write the validated record to DynamoDB with a computed TTL
  4. Emit a structured TELEMETRY_INGESTED event for the CloudWatch metric filter

Failure handling:
  - ValidationError: logged as PAYLOAD_INVALID, function returns without
    writing to DynamoDB. The rules engine does not retry on Lambda success,
    so this is effectively a dead-end for malformed payloads. That's correct
    behaviour — a malformed payload retried indefinitely provides no value.
  - Any other exception: re-raised so Lambda retries (up to 2 times) and
    then routes the event to the SQS DLQ. DLQ depth > 0 triggers an alarm.

Structured logging:
  Every log line is a JSON object with an "event_type" field. CloudWatch
  metric filters in cloudwatch.tf match on this field to increment custom
  metrics without the Lambda function calling PutMetricData directly.

  Event types emitted:
    TELEMETRY_INGESTED       — successful write (every valid message)
    TEMPERATURE_EXCURSION    — temp_c > TEMP_EXCURSION_THRESHOLD_C
    BATTERY_LOW              — battery_pct < BATTERY_LOW_THRESHOLD_PCT
    SHOCK_EVENT              — shock_g > 2.0g
    PAYLOAD_INVALID          — ValidationError from models.py
    DUPLICATE_DROPPED        — DynamoDB conditional check failed (at-least-once delivery)
"""

import json
import logging
import os
from datetime import datetime, timezone, timedelta
from typing import Any

import boto3
from botocore.exceptions import ClientError

from models import TelemetryPayload, ValidationError

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DYNAMODB_TABLE              = os.environ["DYNAMODB_TABLE"]
TEMP_EXCURSION_THRESHOLD_C  = float(os.environ.get("TEMP_EXCURSION_THRESHOLD_C", "8.0"))
BATTERY_LOW_THRESHOLD_PCT   = float(os.environ.get("BATTERY_LOW_THRESHOLD_PCT", "15.0"))
TELEMETRY_TTL_DAYS          = int(os.environ.get("TELEMETRY_TTL_DAYS", "90"))
LOG_LEVEL                   = os.environ.get("LOG_LEVEL", "INFO").upper()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger()
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))


def log(event_type: str, **kwargs: Any) -> None:
    """
    Emit a structured JSON log event. CloudWatch metric filters match on
    the 'event_type' field to increment custom metrics.
    """
    record = {
        "event_type": event_type,
        "ingested_at": datetime.now(timezone.utc).isoformat(),
        **kwargs,
    }
    logger.info(json.dumps(record))


# ---------------------------------------------------------------------------
# DynamoDB client — module-level for connection reuse across warm invocations
# ---------------------------------------------------------------------------

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(DYNAMODB_TABLE)


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def lambda_handler(event: dict, context: Any) -> dict:
    """
    Entry point. IoT Core rules engine passes the full JSON payload as event.
    """
    try:
        payload = TelemetryPayload.from_dict(event)
    except ValidationError as exc:
        log(
            "PAYLOAD_INVALID",
            device_id=event.get("device_id", "UNKNOWN"),
            errors=exc.errors,
            raw_event=event,
        )
        # Return success to IoT Core — retrying a malformed payload is pointless.
        return {"status": "rejected", "reason": "validation_error"}

    _check_excursions(payload)
    _write_telemetry(payload)

    log(
        "TELEMETRY_INGESTED",
        device_id=payload.device_id,
        timestamp=payload.timestamp,
        temperature_c=payload.temperature_c,
        humidity_pct=payload.humidity_pct,
        shock_g=payload.shock_g,
        battery_pct=payload.battery_pct,
        fleet_id=payload.fleet_id,
    )

    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Excursion detection
# ---------------------------------------------------------------------------

def _check_excursions(payload: TelemetryPayload) -> None:
    """
    Evaluate threshold conditions and emit structured log events.
    CloudWatch metric filters in cloudwatch.tf pick these up.
    """
    if payload.temperature_c > TEMP_EXCURSION_THRESHOLD_C:
        log(
            "TEMPERATURE_EXCURSION",
            device_id=payload.device_id,
            timestamp=payload.timestamp,
            temperature_c=payload.temperature_c,
            threshold_c=TEMP_EXCURSION_THRESHOLD_C,
            latitude=payload.latitude,
            longitude=payload.longitude,
            fleet_id=payload.fleet_id,
        )

    if payload.battery_pct < BATTERY_LOW_THRESHOLD_PCT:
        log(
            "BATTERY_LOW",
            device_id=payload.device_id,
            timestamp=payload.timestamp,
            battery_pct=payload.battery_pct,
            threshold_pct=BATTERY_LOW_THRESHOLD_PCT,
            fleet_id=payload.fleet_id,
        )

    if payload.shock_g > 2.0:
        log(
            "SHOCK_EVENT",
            device_id=payload.device_id,
            timestamp=payload.timestamp,
            shock_g=payload.shock_g,
            latitude=payload.latitude,
            longitude=payload.longitude,
            fleet_id=payload.fleet_id,
        )


# ---------------------------------------------------------------------------
# DynamoDB write
# ---------------------------------------------------------------------------

def _write_telemetry(payload: TelemetryPayload) -> None:
    """
    Write a validated telemetry record to DynamoDB.

    Uses a conditional write to handle at-least-once delivery from IoT Core —
    duplicate device_id + timestamp combinations are dropped silently.
    """
    now_utc = datetime.now(timezone.utc)
    expires_at = int((now_utc + timedelta(days=TELEMETRY_TTL_DAYS)).timestamp())

    item = {
        "device_id":     payload.device_id,
        "timestamp":     payload.timestamp,
        "ingested_at":   now_utc.isoformat(),
        "latitude":      str(payload.latitude),
        "longitude":     str(payload.longitude),
        "temperature_c": str(payload.temperature_c),
        "humidity_pct":  str(payload.humidity_pct),
        "shock_g":       str(payload.shock_g),
        "battery_pct":   str(payload.battery_pct),
        "expires_at":    expires_at,
    }

    if payload.fleet_id:
        item["fleet_id"] = payload.fleet_id
    if payload.firmware_version:
        item["firmware_version"] = payload.firmware_version

    try:
        table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(#ts)",
            ExpressionAttributeNames={"#ts": "timestamp"},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            log(
                "DUPLICATE_DROPPED",
                device_id=payload.device_id,
                timestamp=payload.timestamp,
            )
            return
        raise
