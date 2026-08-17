import csv
import io
import math
import re

from db import format_time

LAP_MARKER = re.compile(r"^#\s*Lap\s+(\d+):\s*([\d:.]+)")

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


def parse_log(text: str) -> dict:
    lap_times: dict[int, float] = {}
    header: list[str] | None = None
    laps: dict[int, dict] = {}

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            marker = LAP_MARKER.match(line)
            if marker:
                lap_times[int(marker.group(1))] = _marker_seconds(marker.group(2))
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
        result.append(entry)
    return {"laps": result}
