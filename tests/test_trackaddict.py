import trackaddict


def _laps(text: str) -> dict[int, dict]:
    return {lap["lap"]: lap for lap in trackaddict.parse_log(text)["laps"]}


def _without_sectors(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.startswith("# Sector")
    )


def _faster(text: str, mph: float) -> str:
    out = []
    for line in text.splitlines():
        if line[:1].isdigit():
            *rest, speed = line.split(",")
            line = ",".join([*rest, f"{float(speed) + mph:.1f}"])
        out.append(line)
    return "\n".join(out)


def test_quarter_mile_run(drag_log):
    laps = _laps(drag_log)
    assert laps[1]["acceleration"] == {
        "zero_to_30_seconds": 4.23,
        "zero_to_60_seconds": 12.22,
        "eighth_mile_seconds": 11.849,
        "eighth_mile_mph": 59.0,
        "quarter_mile_seconds": 18.44,
        "quarter_mile_mph": 73.0,
    }
    assert "acceleration" not in laps[0]
    assert "acceleration" not in laps[2]


def test_standing_start_without_sector_markers_has_only_speed_times(drag_log):
    laps = _laps(_without_sectors(drag_log))
    assert laps[1]["acceleration"] == {
        "zero_to_30_seconds": 4.23,
        "zero_to_60_seconds": 12.22,
    }


def test_rolling_start_has_no_acceleration(drag_log):
    laps = _laps(_faster(_without_sectors(drag_log), 25))
    assert laps[1]["time_seconds"] == 18.44
    assert all("acceleration" not in lap for lap in laps.values())


def test_rolling_start_ignores_drag_sectors(drag_log):
    laps = _laps(_faster(drag_log, 25))
    assert all("acceleration" not in lap for lap in laps.values())


def test_eighth_mile_run(drag_log):
    lines = []
    for line in drag_log.splitlines():
        if line.startswith(("# Sector 3", "# Sector 4")):
            continue
        if line.startswith("# Lap 1"):
            line = "# Lap 1: 00:00:11.849"
        lines.append(line)
    acceleration = _laps("\n".join(lines))[1]["acceleration"]
    assert acceleration["eighth_mile_seconds"] == 11.849
    assert acceleration["eighth_mile_mph"] == 59.0
    assert "quarter_mile_seconds" not in acceleration
    assert "quarter_mile_mph" not in acceleration


def test_lift_before_sixty_drops_zero_to_sixty(drag_log):
    lines = []
    for line in drag_log.splitlines():
        if line[:1].isdigit():
            time, *middle, speed = line.split(",")
            if 9 < float(time) < 12:
                speed = "30.5"
            line = ",".join([time, *middle, speed])
        lines.append(line)
    acceleration = _laps("\n".join(lines))[1]["acceleration"]
    assert acceleration["zero_to_30_seconds"] == 4.23
    assert "zero_to_60_seconds" not in acceleration


def test_second_run_in_one_file(drag_log):
    head = drag_log.splitlines()[:2]
    rows = [line.split(",") for line in drag_log.splitlines() if line[:1].isdigit()]
    gap = 60.0
    again = [
        [f"{gap + float(t):.3f}", str(int(lap) + 2), *rest] for t, lap, *rest in rows
    ]
    markers = ["# Sector 2: 00:00:11.849 (200m)", "# Sector 4: 00:00:18.440 (400m)"]
    text = "\n".join(
        [
            *head,
            *(",".join(row) for row in rows),
            "# Lap 0: 00:00:01.811",
            *markers,
            "# Lap 1: 00:00:18.440",
            f"# Lap 2: 00:00:{gap - 18.44:06.3f}",
            *(",".join(row) for row in again),
            *markers,
            "# Lap 3: 00:00:18.440",
        ]
    )
    laps = _laps(text)
    assert laps[3]["acceleration"] == laps[1]["acceleration"]
    assert "acceleration" not in laps[2]


def test_parse_endpoint(client, drag_log):
    parsed = client.post("/api/trackaddict/parse", content=drag_log)
    assert parsed.status_code == 200
    assert parsed.json() == trackaddict.parse_log(drag_log)
    assert client.post("/api/trackaddict/parse", content=" ").status_code == 400
