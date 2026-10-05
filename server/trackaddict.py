import csv
import io
import math
import re
from itertools import pairwise

from db import format_time

LAP_MARKER = re.compile(r"^#\s*Lap\s+(\d+):\s*([\d:.]+)")
SECTOR_MARKER = re.compile(r"^#\s*Sector\s+\d+:\s*([\d:.]+)\s*\((\d+)m\)")

# Drag mode marks a sector every 100 m and treats 400 m as the quarter mile.
STRIP_METERS = {200: "eighth_mile", 400: "quarter_mile"}
STANDING_START_MPH = 5.0
# A drop this far below the peak means the driver lifted, so a later crossing
# of a target speed belongs to a different pull.
LIFT_MPH = 5.0

EARTH_RADIUS_MILES = 3958.8


def _marker_seconds(text: str) -> float:
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def _haversine_miles(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_MILES * math.asin(math.sqrt(a))


def _speed_at(samples: list[tuple[float, float]], when: float) -> float | None:
    for (t0, s0), (t1, s1) in pairwise(samples):
        if t0 <= when <= t1:
            return s0 + (s1 - s0) * (when - t0) / (t1 - t0)
    return None


def _seconds_to_speed(
    samples: list[tuple[float, float]], start: float, target: float
) -> float | None:
    peak = 0.0
    for (t0, s0), (t1, s1) in pairwise(samples):
        if t1 <= start:
            continue
        if s1 < peak - LIFT_MPH:
            return None
        peak = max(peak, s1)
        if s0 < target <= s1:
            return t0 + (t1 - t0) * (target - s0) / (s1 - s0) - start
    return None


def _acceleration(
    samples: list[tuple[float, float]], start: float, sectors: list[tuple[int, float]]
) -> dict:
    launch_speed = _speed_at(samples, start)
    if launch_speed is None or launch_speed > STANDING_START_MPH:
        return {}
    out = {}
    for target in (30, 60):
        seconds = _seconds_to_speed(samples, start, target)
        if seconds is not None:
            out[f"zero_to_{target}_seconds"] = round(seconds, 2)
    for meters, seconds in sectors:
        name = STRIP_METERS.get(meters)
        if name is None:
            continue
        out[f"{name}_seconds"] = seconds
        trap = _speed_at(samples, start + seconds)
        if trap is not None:
            out[f"{name}_mph"] = round(trap, 1)
    return out


def parse_log(text: str) -> dict:
    lap_times: dict[int, float] = {}
    header: list[str] | None = None
    laps: dict[int, dict] = {}
    sectors: dict[int, list[tuple[int, float]]] = {}
    pending_sectors: list[tuple[int, float]] = []
    samples: list[tuple[float, float]] = []

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            marker = LAP_MARKER.match(line)
            if marker:
                lap_times[int(marker.group(1))] = _marker_seconds(marker.group(2))
                sectors[int(marker.group(1))] = pending_sectors
                pending_sectors = []
            sector = SECTOR_MARKER.match(line)
            if sector:
                pending_sectors.append(
                    (int(sector.group(2)), _marker_seconds(sector.group(1)))
                )
            continue
        row = next(csv.reader(io.StringIO(line)))
        if header is None:
            header = row
            continue
        record = dict(zip(header, row))
        try:
            lap = int(record["Lap"])
            speed = float(record["Speed (MPH)"])
            lat = float(record["Latitude"])
            lon = float(record["Longitude"])
        except (KeyError, ValueError):
            continue
        stats = laps.setdefault(
            lap, {"top_speed_mph": 0.0, "distance_miles": 0.0, "last_point": None}
        )
        stats["top_speed_mph"] = max(stats["top_speed_mph"], speed)
        if record.get("GPS_Update") == "1":
            try:
                samples.append((float(record["Time"]), speed))
            except (KeyError, ValueError):
                pass
            if stats["last_point"] is not None:
                stats["distance_miles"] += _haversine_miles(
                    *stats["last_point"], lat, lon
                )
            stats["last_point"] = (lat, lon)

    result = []
    for lap in sorted(set(lap_times) | set(laps)):
        stats = laps.get(lap, {})
        time_seconds = lap_times.get(lap)
        distance = stats.get("distance_miles")
        entry = {
            "lap": lap,
            "time_seconds": time_seconds,
            "top_speed_mph": stats.get("top_speed_mph"),
            "distance_miles": round(distance, 3) if distance is not None else None,
        }
        if time_seconds:
            entry["time"] = format_time(time_seconds)
            if distance:
                entry["avg_speed_mph"] = round(distance / time_seconds * 3600, 2)
        if lap > 0 and all(earlier in lap_times for earlier in range(lap)):
            start = sum(lap_times[earlier] for earlier in range(lap))
            acceleration = _acceleration(samples, start, sectors.get(lap, []))
            if acceleration:
                entry["acceleration"] = acceleration
        result.append(entry)
    return {"laps": result}
