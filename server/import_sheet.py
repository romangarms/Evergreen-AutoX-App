"""One-shot import of the leaderboard Google Sheets into leaderboard.db: the
'HWY 9 Leaderboard' (CA), the Cannonball and Disco sheets (WA), and the
acceleration sheet.

Safe to re-run: existing courses, runs and acceleration entries are left untouched.
"""

import db

SKIDPAD = {
    "name": "Skidpad to 4 Corners Uphill",
    "distance_miles": 1.65,
    "legacy_distance_miles": 1.7,
    "region": "CA",
}
INTRO = {
    "name": "Intro to 9",
    "distance_miles": None,
    "legacy_distance_miles": None,
    "region": "CA",
}
CANNONBALL_NORTH = {
    "name": "Cannonball North",
    "distance_miles": 79,
    "legacy_distance_miles": None,
    "region": "WA",
}
CANNONBALL_SOUTH = {
    "name": "Cannonball South",
    "distance_miles": 79,
    "legacy_distance_miles": None,
    "region": "WA",
}
DISCO = {
    "name": "Disco Run",
    "distance_miles": None,
    "legacy_distance_miles": None,
    "region": "WA",
}

SKIDPAD_RUNS = [
    (
        "1:18.341",
        350,
        "2001 C5 Corvette",
        78.12,
        110.7,
        "JH",
        "8/7/26",
        "8:00 PM",
        "Dry",
        True,
    ),
    (
        "1:16.634",
        305,
        "2000 Camaro Z28",
        77.51,
        104.5,
        "JH",
        "6/12/26",
        "9:00 PM",
        "Dry",
        False,
    ),
    (
        "1:19.231",
        350,
        "2007 BMW Z4M",
        77.24,
        102.5,
        "RG",
        "5/3/26",
        "7:00 PM",
        "Dry",
        True,
    ),
    (
        "1:22.781",
        166,
        "2006 Honda Accord",
        73.93,
        94.7,
        "RB",
        "4/5/26",
        "11:00 AM",
        "Dry",
        True,
    ),
    (
        "1:24.436",
        250,
        "2023 Mazda 3 Turbo",
        72.48,
        95.7,
        "RG",
        "6/12/25",
        "10:00 PM",
        "Dry",
        True,
    ),
    (
        "1:28.313",
        120,
        "2013 Mini Clubman",
        69.30,
        82.6,
        "SH",
        "6/12/25",
        "10:00 PM",
        "Dry",
        True,
    ),
    (
        "1:28.677",
        205,
        "2015 Mazda 3",
        69.01,
        92,
        "RG",
        "1/25/25",
        "11:00 PM",
        "Dry",
        True,
    ),
    (
        "1:29.570",
        150,
        "1986 Porsche 944",
        68.33,
        84,
        "GM",
        "11/30/25",
        "7:00 PM",
        "Dry",
        True,
    ),
    (
        "1:30.325",
        135,
        "1996 Mazda Miata",
        67.76,
        87.3,
        "IB",
        "2/17/25",
        "7:00 PM",
        "Dry",
        True,
    ),
    (
        "1:30.533",
        180,
        "2014 Mini Cooper S",
        67.60,
        86.7,
        "CA",
        "7/19/26",
        "11:00 AM",
        "Dry",
        True,
    ),
    (
        "1:27.966",
        155,
        "2017 Mazda Miata RF GT",
        67.53,
        88.8,
        "RB",
        "8/7/26",
        "8:00 PM",
        "Dry",
        False,
    ),
    (
        "1:20.805",
        155,
        "2017 Mazda Miata RF GT",
        73.51,
        95.9,
        "IB",
        "8/29/26",
        "7:00 PM",
        "Dry",
        False,
    ),
    (
        "1:31.369",
        360,
        "2019 BMW 440i",
        66.98,
        93.2,
        "A",
        "4/10/25",
        "10:00 PM",
        "Dry",
        True,
    ),
    (
        "1:31.563",
        368,
        "2018 Kia Stinger",
        66.84,
        94.3,
        "K",
        "2/14/25",
        "9:00 PM",
        "Wet",
        True,
    ),
    (
        "1:34.689",
        220,
        "2003 VW GTI",
        64.63,
        84,
        "GM",
        "2/28/26",
        "11:00 PM",
        "Dry",
        True,
    ),
    (
        "1:34.777",
        350,
        "1966 Ford Mustang",
        64.57,
        79.6,
        "CM",
        "5/7/26",
        "8:00 PM",
        "Dry",
        True,
    ),
    (
        "1:39.889",
        271,
        "1963 Austin Healy",
        61.27,
        81.9,
        "IB",
        "2/22/25",
        "1:00 PM",
        "Dry",
        True,
    ),
    (
        "1:40.059",
        181,
        "1995 Jeep Grand Cherokee",
        61.16,
        81.2,
        "JH",
        "4/27/26",
        "9:00 PM",
        "Dry",
        True,
    ),
    (
        "1:40.922",
        205,
        "2015 Mazda 3",
        60.64,
        81.8,
        "SH",
        "1/25/25",
        "11:00 PM",
        "Dry",
        True,
    ),
    (
        "1:45.360",
        400,
        "2018 Mustang Ecoboost",
        58.09,
        88.6,
        "BS",
        "1/26/25",
        "4:00 PM",
        "Dry",
        True,
    ),
    (
        "1:46.709",
        110,
        "2010 Honda Civic Hybrid",
        57.35,
        72.5,
        "RO",
        "4/5/26",
        "11:00 AM",
        "Dry",
        True,
    ),
    (
        "1:47.110",
        175,
        "2025 Chevy Malibu",
        57.14,
        85.5,
        "RG",
        "1/29/25",
        "10:00 PM",
        "Dry",
        True,
    ),
    (
        "1:56.980",
        127,
        "2001 Honda Civic",
        50.78,
        64.5,
        "RJ",
        "6/7/26",
        "7:00 PM",
        "Dry",
        False,
    ),
]

INTRO_RUNS = [
    (
        "3:01.271",
        205,
        "2015 Mazda 3",
        54.6,
        80.8,
        "RG",
        "1/18/25",
        "9:00 PM",
        "Dry",
        "NB",
    ),
    (
        "3:04.323",
        250,
        "2023 Mazda 3 Turbo",
        53.1,
        84,
        "RG",
        "3/7/25",
        "11:00 PM",
        "Dry",
        "NB",
    ),
    (
        "3:05.41",
        121,
        "2013 Mini Clubman",
        52.9,
        74.3,
        "SH",
        "3/6/25",
        "8:00 PM",
        "Wet",
        "SB",
    ),
    (
        "3:10.485",
        305,
        "2000 Camaro Z28",
        52.4,
        73.7,
        "JH",
        "1/18/25",
        "9:00 PM",
        "Dry",
        "NB",
    ),
    (
        "3:11.558",
        175,
        "2025 Chevy Malibu",
        51.4,
        79.2,
        "RG",
        "1/29/25",
        "9:00 PM",
        "Dry",
        "NB",
    ),
    (
        "3:43.565",
        175,
        "2024 GMC Terrain",
        44,
        67.1,
        "RG",
        "1/27/25",
        "10:00 PM",
        "Dry",
        "NB",
    ),
    (
        "3:53.669",
        360,
        "2019 BMW 440i",
        42.4,
        72.2,
        "A",
        "3/12/25",
        "9:00 PM",
        "Wet",
        "NB",
    ),
    (
        "4:53.977",
        119,
        "1980s BMW 528e",
        35.5,
        50.1,
        "IB",
        "1/18/25",
        "4:00 PM",
        "Dry",
        "NB",
    ),
]

# time, vehicle, top speed, start time, driver, date, conditions, notes
CANNONBALL_NORTH_RUNS = [
    (
        "0:53:28",
        "2006 Honda Odyssey",
        118,
        "11:59 PM",
        "DP",
        "10/15/23",
        "Dark",
        "Speed limiter",
    ),
    ("0:56:38", "2016 Subaru Outback", 124, "10:00 PM", "GK", "7/2/24", "Dark", None),
    ("0:58:26", "2011 Audi A4", 143, "7:00 PM", "RG", "7/25/23", "Day", None),
    (
        "0:58:28",
        "2016 Ford Fiesta",
        120,
        "7:00 PM",
        "TN",
        "7/25/23",
        "Day",
        "Speed limiter",
    ),
    ("1:04:19", "2015 Mazda 3", 121, "10:00 PM", "RG", "8/12/23", "Dark", None),
    ("1:04:38", "2016 Ford Fiesta", 115, "10:00 PM", "TN", "8/12/23", "Dark", None),
    ("1:05:09", "2016 Subaru Outback", 88, "6:00 PM", "GK", "9/21/23", "Day", None),
    (
        "1:14:11",
        "2013 Toyota Highlander",
        110,
        "6:45 PM",
        "RG",
        "3/23/24",
        "Day",
        "Speed limiter",
    ),
    ("2:23:00", "Amtrak train", 48, "7:47", "GK", "9/29/23", "Day", None),
]

# Same columns as CANNONBALL_NORTH_RUNS.
CANNONBALL_SOUTH_RUNS = [
    (
        "1:00:50",
        "2006 Honda Odyssey",
        118,
        "12:00 PM",
        "DP",
        "10/15/23",
        "Day",
        "Speed limiter",
    ),
    (
        "1:01:22",
        "2016 Ford Fiesta",
        120,
        "5:00 PM",
        "TN",
        "9/16/23",
        "Day",
        "Speed limiter",
    ),
    (
        "1:01:50",
        "2015 Mazda 3",
        129,
        "5:00 PM",
        "RG",
        "9/16/23",
        "Day",
        "Speed limiter",
    ),
    ("1:02:00", "1999 Mazda Miata", 120, "5:00 PM", "IS", "9/16/23", "Day", None),
    ("1:02:10", "2016 Ford Fiesta", 100, "1:00 PM", "TN", "1/14/24", "Day", None),
    (
        "1:02:40",
        "2006 Toyota Camry",
        125,
        "12:00 PM",
        "TT",
        "11/1/23",
        "Day",
        "Speed limiter",
    ),
    ("1:03:32", "2011 Mini Cooper S", 115, "12:00 PM", "LD", "11/1/23", "Day", None),
    ("1:05:00", "2016 Jeep Grand Cherokee", 85, "9:30 AM", "TN", "8/2/23", "Day", None),
    (
        "1:07:04",
        "2019 Nissan Leaf",
        98,
        "9:40 AM",
        "HC",
        "8/31/23",
        "Day",
        "Speed limiter",
    ),
    ("1:09:21", "1988 Pontiac Firebird", 105, "10:00 AM", "GK", "2/20/24", "Day", None),
    ("1:11:16", "2016 Subaru Outback", 88, "1:00 PM", "GK", "9/21/23", "Day", None),
    (
        "1:11:49",
        "2013 Toyota Highlander",
        105,
        "12:30 PM",
        "RG",
        "3/23/24",
        "Day",
        None,
    ),
    ("1:18:30", "1988 Pontiac Firebird", 85, "8:10 PM", "GK", "3/2/24", "Dark", None),
    ("1:29:19", "2011 Audi A4", 138, "3:00 PM", "RG", "7/25/23", "Day", None),
    ("1:29:19", "2016 Ford Fiesta", 110, "3:00 PM", "TN", "7/25/23", "Day", None),
    (
        "16:21:00",
        "bicycle, amtrack, afroman?",
        50,
        "6:17 PM",
        "GK",
        "10/1/23",
        "Day",
        None,
    ),
]

# time, vehicle, driver, date, direction
DISCO_RUNS = [
    ("1:24.4", "2016 Ford Fiesta", "TN", "11/15/23", "Downhill"),
    ("1:31.0", "2011 Mini Cooper S", "LD", "11/16/23", "Downhill"),
    ("2:04.02", "2006 Honda Odyssey", "DP", "1/1/24", None),
]

# year, vehicle, driver, hp, weight, 0-30, 0-60, 1/4 time, 1/4 mph, 1/8 time, 1/8 mph
ACCELERATION = [
    (2001, "C5 Corvette", "JH", 345, 3200, None, 4.8, 11.983, 95.9, None, None),
    (
        2023,
        "Mazda 3 Turbo (tuned)",
        "RG",
        280,
        3400,
        1.77,
        5.2,
        None,
        None,
        8.813,
        80.6,
    ),
    (2023, "Mazda 3 Turbo", "RG", 250, 3400, 1.83, 5.5, 14.4905, 95.15, 8.997, 77.6),
    (2007, "BMW Z4M", "RG", 350, 3200, 3.24, 5.8, None, None, 8.46, 78.6),
    (2000, "Camaro Z28", "JH", 305, 3500, None, 6.3, None, None, 9.21, 66.6),
    (2007, "BMW 328i", "TN", 240, 3400, None, 6.65, 14.58, 96.05, 9.5665, 75.55),
    (
        1963,
        "Austin Healy 3000 MKII",
        "IB",
        271,
        None,
        2.75,
        7.09,
        None,
        None,
        None,
        None,
    ),
    (2015, "Mazda 3 (tuned)", "RG", 205, 3000, 3.34, 7.2, None, None, None, None),
    (1988, "Pontiac Firebird", "RG", 200, 3400, 3.37, 7.8, None, None, 10.017, 70.7),
    (2025, "Chevy Malibu", "RG", 175, 3100, 2.95, 8.1, None, None, None, None),
    (2015, "Mazda 3", "RG", 185, 3000, 3.5, 8.2, None, None, None, None),
    (2010, "Subaru Impreza", "KJ", 170, None, 3.4, 8.8, None, None, None, None),
    (1996, "Mazda Miata", "IB", 131, None, 2.99, 8.99, None, None, None, None),
    (2006, "Toyota Camry", "TE", 154, None, 4.15, 9.8, None, None, None, None),
    (2006, "Honda Odyssey", "DP", 244, None, 4, 9.83, None, None, None, None),
    (2013, "Mini Clubman", "SH", 120, None, 3.45, 10.5, None, None, None, None),
    (2016, "Subaru Outback", "GK", 182, None, 4.42, 10.69, None, None, None, None),
    (2004, "Nissan Xterra 4x4", "RG", 180, 4200, 4.24, 12.3, 18.44, 73, 11.849, 59),
    (1996, "Toyota Tacoma", "IB", 150, None, 5.09, 12.6, None, None, None, None),
    (1990, "Avon Supersport Boat", "TN", 30, None, 7.6, None, None, None, None, None),
    (2023, "Tweaker Bike 2", None, 2, None, None, None, None, None, None, None),
]


def iso_date(us_date: str) -> str:
    month, day, year = us_date.split("/")
    return f"20{year}-{int(month):02d}-{int(day):02d}"


def ensure_course(conn, course: dict) -> int:
    row = conn.execute(
        "SELECT id FROM courses WHERE name = ?", (course["name"],)
    ).fetchone()
    if row:
        conn.execute(
            "UPDATE courses SET region = ? WHERE id = ? AND region IS NULL",
            (course["region"], row["id"]),
        )
        return row["id"]
    cur = conn.execute(
        """INSERT INTO courses (name, distance_miles, legacy_distance_miles, region)
           VALUES (?, ?, ?, ?)""",
        (
            course["name"],
            course["distance_miles"],
            course["legacy_distance_miles"],
            course["region"],
        ),
    )
    return cur.lastrowid


def insert_run(
    conn,
    course_id,
    time,
    hp,
    vehicle,
    avg,
    top,
    driver,
    date,
    tod,
    conditions,
    legacy,
    notes,
):
    seconds = db.parse_time(time)
    run_date = iso_date(date)
    exists = conn.execute(
        "SELECT 1 FROM runs WHERE course_id = ? AND driver = ? AND time_seconds = ? AND run_date = ?",
        (course_id, driver, seconds, run_date),
    ).fetchone()
    if exists:
        return False
    conn.execute(
        """INSERT INTO runs (course_id, driver, vehicle, hp, time_seconds, avg_speed_mph,
            top_speed_mph, run_date, time_of_day, conditions, legacy, notes, source)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'sheet')""",
        (
            course_id,
            driver,
            vehicle,
            hp,
            seconds,
            avg,
            top,
            run_date,
            tod,
            conditions,
            int(legacy),
            notes,
        ),
    )
    return True


def insert_acceleration(conn, entry: tuple) -> bool:
    year, vehicle, driver = entry[:3]
    exists = conn.execute(
        "SELECT 1 FROM acceleration_entries WHERE year IS ? AND vehicle = ? AND driver IS ?",
        (year, vehicle, driver),
    ).fetchone()
    if exists:
        return False
    conn.execute(
        """INSERT INTO acceleration_entries (year, vehicle, driver, hp, weight_lb,
            zero_to_30_seconds, zero_to_60_seconds, quarter_mile_seconds,
            quarter_mile_mph, eighth_mile_seconds, eighth_mile_mph, source)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'sheet')""",
        entry,
    )
    return True


def main():
    with db.session() as conn:
        skidpad_id = ensure_course(conn, SKIDPAD)
        intro_id = ensure_course(conn, INTRO)
        added = 0
        for (
            time,
            hp,
            vehicle,
            avg,
            top,
            driver,
            date,
            tod,
            cond,
            legacy,
        ) in SKIDPAD_RUNS:
            added += insert_run(
                conn,
                skidpad_id,
                time,
                hp,
                vehicle,
                avg,
                top,
                driver,
                date,
                tod,
                cond,
                legacy,
                None,
            )
        for (
            time,
            hp,
            vehicle,
            avg,
            top,
            driver,
            date,
            tod,
            cond,
            direction,
        ) in INTRO_RUNS:
            added += insert_run(
                conn,
                intro_id,
                time,
                hp,
                vehicle,
                avg,
                top,
                driver,
                date,
                tod,
                cond,
                False,
                direction,
            )
        for course, runs in (
            (CANNONBALL_NORTH, CANNONBALL_NORTH_RUNS),
            (CANNONBALL_SOUTH, CANNONBALL_SOUTH_RUNS),
        ):
            course_id = ensure_course(conn, course)
            for time, vehicle, top, tod, driver, date, cond, notes in runs:
                added += insert_run(
                    conn,
                    course_id,
                    time,
                    None,
                    vehicle,
                    None,
                    top,
                    driver,
                    date,
                    tod,
                    cond,
                    False,
                    notes,
                )
        disco_id = ensure_course(conn, DISCO)
        for time, vehicle, driver, date, direction in DISCO_RUNS:
            added += insert_run(
                conn,
                disco_id,
                time,
                None,
                vehicle,
                None,
                None,
                driver,
                date,
                None,
                None,
                False,
                direction,
            )
        accel_added = sum(insert_acceleration(conn, entry) for entry in ACCELERATION)
        total = conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0]
    print(
        f"Imported {added} new runs ({total} total) and {accel_added} new"
        f" acceleration entries into {db.DB_PATH}"
    )


if __name__ == "__main__":
    main()
