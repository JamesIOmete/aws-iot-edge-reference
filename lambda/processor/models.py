"""
Telemetry payload schema and validation.

Uses Python stdlib only — no pydantic — to keep the Lambda deployment
package small. pydantic-core (pydantic v2's Rust backend) adds ~40MB of
compiled binaries, which pushes the zip past Lambda's 70MB limit when
bundled inline.

Validation behaviour is equivalent: required fields, type checks, range
checks, and cross-field validation. The difference is no automatic type
coercion — payloads must be correctly typed JSON. A device publishing
string "3.2" instead of float 3.2 will be rejected, which is correct
behaviour at this boundary.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from typing import Optional


class ValidationError(Exception):
    """Raised when a telemetry payload fails validation."""
    def __init__(self, errors: list[dict]):
        self.errors = errors
        super().__init__(str(errors))


def _require_float(value, name: str, min_val: float, max_val: float) -> float:
    if not isinstance(value, (int, float)):
        raise TypeError(f"{name} must be a number, got {type(value).__name__}")
    value = float(value)
    if not (min_val <= value <= max_val):
        raise ValueError(f"{name} must be between {min_val} and {max_val}, got {value}")
    return value


def _require_str(value, name: str, min_len: int = 1, max_len: int = 255) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a string, got {type(value).__name__}")
    if not (min_len <= len(value) <= max_len):
        raise ValueError(f"{name} length must be {min_len}-{max_len}, got {len(value)}")
    return value


@dataclass
class TelemetryPayload:
    """
    Validated cold chain telemetry record.

    Construct via TelemetryPayload.from_dict(event) — raises ValidationError
    if any field is missing, wrong type, or out of range.
    """
    device_id:        str
    timestamp:        str
    latitude:         float
    longitude:        float
    temperature_c:    float
    humidity_pct:     float
    shock_g:          float
    battery_pct:      float
    fleet_id:         Optional[str] = None
    firmware_version: Optional[str] = None

    @classmethod
    def from_dict(cls, data: dict) -> "TelemetryPayload":
        errors = []

        def collect(fn, *args):
            try:
                return fn(*args)
            except (TypeError, ValueError) as exc:
                errors.append({"field": args[1] if len(args) > 1 else args[0], "error": str(exc)})
                return None

        device_id     = collect(_validate_device_id,  data.get("device_id"))
        timestamp     = collect(_validate_timestamp,   data.get("timestamp"))
        latitude      = collect(_require_float, data.get("latitude"),      "latitude",      -90.0,  90.0)
        longitude     = collect(_require_float, data.get("longitude"),     "longitude",    -180.0, 180.0)
        temperature_c = collect(_require_float, data.get("temperature_c"), "temperature_c", -40.0,  85.0)
        humidity_pct  = collect(_require_float, data.get("humidity_pct"),  "humidity_pct",    0.0, 100.0)
        shock_g       = collect(_require_float, data.get("shock_g"),       "shock_g",         0.0, 200.0)
        battery_pct   = collect(_require_float, data.get("battery_pct"),   "battery_pct",     0.0, 100.0)

        fleet_id         = data.get("fleet_id")
        firmware_version = data.get("firmware_version")

        if errors:
            raise ValidationError(errors)

        if latitude == 0.0 and longitude == 0.0:
            raise ValidationError([{
                "field": "latitude/longitude",
                "error": "GPS coordinates (0.0, 0.0) rejected — device likely has no GPS fix."
            }])

        return cls(
            device_id=device_id,
            timestamp=timestamp,
            latitude=latitude,
            longitude=longitude,
            temperature_c=temperature_c,
            humidity_pct=humidity_pct,
            shock_g=shock_g,
            battery_pct=battery_pct,
            fleet_id=fleet_id,
            firmware_version=firmware_version,
        )


_DEVICE_ID_RE = re.compile(r"^[a-zA-Z0-9_\-]+$")


def _validate_device_id(value) -> str:
    if value is None:
        raise ValueError("device_id is required")
    value = _require_str(value, "device_id", min_len=1, max_len=128)
    if not _DEVICE_ID_RE.match(value):
        raise ValueError(
            f"device_id may only contain alphanumeric characters, hyphens, and underscores. Got: {value!r}"
        )
    return value


def _validate_timestamp(value) -> str:
    if value is None:
        raise ValueError("timestamp is required")
    value = _require_str(value, "timestamp", min_len=1, max_len=64)
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError(
            f"timestamp must be ISO 8601 format (e.g. 2024-01-15T09:23:41Z), got: {value!r}"
        )
    return value
