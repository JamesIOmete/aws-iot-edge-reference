"""
Cold chain telemetry payload generator.

Produces realistic sensor readings for a refrigerated cargo device in transit.
The goal is a plausible signal — not random noise — so the CloudWatch dashboard
and alarms behave as they would with a real device.

Simulation model:
  - Temperature: mean-reverting around a setpoint with occasional drift events
    (door opens, ambient temperature fluctuation). Drift events are the primary
    source of excursion alarms.
  - Humidity: correlated with temperature drift — door-open events raise both.
  - Shock: near-zero baseline with occasional spikes (road bumps, loading events).
  - Battery: monotonic drain with a configurable drain rate. No recharge modelled.
  - GPS: linear interpolation along a fixed route with small jitter.
"""

import math
import random
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional


# ---------------------------------------------------------------------------
# Route — fixed lat/lon waypoints simulating a cargo route.
# The generator interpolates between waypoints over the run duration.
# Replace with real coordinates for a geographically meaningful demo.
# ---------------------------------------------------------------------------

# Portland, OR → Seattle, WA (approximate)
DEFAULT_ROUTE = [
    (45.5051, -122.6750),  # Portland, OR
    (45.6887, -122.6615),  # Vancouver, WA
    (46.1460, -122.9390),  # Longview, WA
    (46.9787, -123.8313),  # Aberdeen, WA
    (47.2529, -122.4443),  # Tacoma, WA
    (47.6062, -122.3321),  # Seattle, WA
]


@dataclass
class SimulatorState:
    """
    Mutable state carried between readings.
    Initialized once per simulator session; updated on each tick.
    """
    # Temperature model
    temperature_c: float = 3.0          # Starting temp — within cold chain range
    temp_setpoint: float = 3.0          # Target temperature
    temp_drift_active: bool = False     # True during a drift event
    temp_drift_remaining: int = 0       # Ticks remaining in current drift event

    # Humidity model
    humidity_pct: float = 65.0

    # Battery — drains monotonically
    battery_pct: float = 100.0
    battery_drain_per_tick: float = 0.02  # ~1.2%/hour at 60s ticks

    # GPS position — index into route, interpolated
    route_progress: float = 0.0         # 0.0 = start, 1.0 = end

    # Tick counter
    tick: int = 0


def _interpolate_gps(progress: float, route: list[tuple[float, float]]) -> tuple[float, float]:
    """
    Linear interpolation along a multi-segment route.
    progress: 0.0 (start) → 1.0 (end)
    Returns (latitude, longitude).
    """
    if progress <= 0.0:
        return route[0]
    if progress >= 1.0:
        return route[-1]

    segments = len(route) - 1
    scaled = progress * segments
    idx = min(int(scaled), segments - 1)
    t = scaled - idx

    lat1, lon1 = route[idx]
    lat2, lon2 = route[idx + 1]

    lat = lat1 + t * (lat2 - lat1)
    lon = lon1 + t * (lon2 - lon1)

    # Small GPS jitter — real devices have ~3-5m accuracy
    lat += random.gauss(0, 0.00002)
    lon += random.gauss(0, 0.00002)

    return round(lat, 6), round(lon, 6)


def generate_payload(
    device_id: str,
    state: SimulatorState,
    fleet_id: Optional[str] = None,
    firmware_version: Optional[str] = None,
    route: list[tuple[float, float]] = DEFAULT_ROUTE,
    total_ticks: int = 3600,  # Total expected ticks in the run (for route progress)
) -> dict:
    """
    Advance the simulator state by one tick and return a telemetry payload dict.

    The payload schema matches TelemetryPayload in lambda/processor/models.py.
    Changes to the schema must be reflected in both places.
    """
    state.tick += 1

    # --- Temperature model ---------------------------------------------------
    # Mean reversion: temperature drifts toward setpoint each tick.
    # Occasional drift events push it above threshold to trigger alarms.

    if state.temp_drift_active:
        # During a drift event, temperature climbs toward a higher target
        state.temperature_c += random.gauss(0.15, 0.05)
        state.temp_drift_remaining -= 1
        if state.temp_drift_remaining <= 0:
            state.temp_drift_active = False
    else:
        # Normal operation: mean reversion toward setpoint
        reversion = 0.1 * (state.temp_setpoint - state.temperature_c)
        noise = random.gauss(0, 0.08)
        state.temperature_c += reversion + noise

        # ~1% chance of a drift event per tick (door open, ambient heat)
        if random.random() < 0.01:
            state.temp_drift_active = True
            state.temp_drift_remaining = random.randint(3, 12)  # 3–12 ticks of drift

    state.temperature_c = round(
        max(-5.0, min(state.temperature_c, 25.0)), 2
    )

    # --- Humidity model ------------------------------------------------------
    # Correlated with temperature: rises during drift events, mean-reverts otherwise
    humidity_target = 75.0 if state.temp_drift_active else 65.0
    state.humidity_pct += 0.05 * (humidity_target - state.humidity_pct) + random.gauss(0, 0.3)
    state.humidity_pct = round(max(40.0, min(state.humidity_pct, 95.0)), 1)

    # --- Shock model ---------------------------------------------------------
    # Near-zero baseline; occasional spikes from road events
    if random.random() < 0.03:  # 3% chance of a shock event
        shock_g = round(random.uniform(0.5, 8.0), 3)
    else:
        shock_g = round(abs(random.gauss(0, 0.015)), 3)

    # --- Battery model -------------------------------------------------------
    state.battery_pct -= state.battery_drain_per_tick
    state.battery_pct = round(max(0.0, state.battery_pct), 1)

    # --- GPS model -----------------------------------------------------------
    state.route_progress = min(1.0, state.tick / max(total_ticks, 1))
    latitude, longitude = _interpolate_gps(state.route_progress, route)

    # --- Assemble payload ----------------------------------------------------
    payload = {
        "device_id": device_id,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "latitude": latitude,
        "longitude": longitude,
        "temperature_c": state.temperature_c,
        "humidity_pct": state.humidity_pct,
        "shock_g": shock_g,
        "battery_pct": state.battery_pct,
    }

    if fleet_id:
        payload["fleet_id"] = fleet_id
    if firmware_version:
        payload["firmware_version"] = firmware_version

    return payload
