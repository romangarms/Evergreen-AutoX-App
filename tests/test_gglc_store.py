from datetime import date
from types import SimpleNamespace

import cache
import gglc
import gglc_pdf
import httpx
import pytest

TODAY = date(2026, 9, 13)
PAST = date(2026, 9, 12)

PAGE = """<h1>GGLC Autocross Result</h1><p>Updated 04:36PM</p>
<table>
<tr><th>Lotus Elise</th></tr>
<tr><th>Name</th><th>Car</th><th>Make</th><th>Model</th><th>Class</th>
<th>PAX</th><th>Indexed</th><th>Run 1</th><th>Run 2</th><th>Best</th></tr>
<tr><td>Will</td><td>2</td><td>Lotus</td><td>Elise</td><td>Lotus Elise</td>
<td>0.871</td><td>51.421</td><td>{run1}</td>
<td style="background-color:lightgreen">59.016</td><td>59.016</td></tr>
</table>"""


@pytest.fixture
def gglc_site(client, monkeypatch):
    pages = {}

    def handle(request):
        html = pages.get(str(request.url))
        if html is None:
            return httpx.Response(404)
        return httpx.Response(200, text=html)

    monkeypatch.setattr(
        gglc, "_http", httpx.Client(transport=httpx.MockTransport(handle))
    )
    monkeypatch.setattr(gglc, "today", lambda: TODAY)
    cache.clear()
    for name in ("_event_cache", "_saved", "_shrunk_since"):
        monkeypatch.setattr(gglc, name, {})
    for name in ("_found", "_missing"):
        monkeypatch.setattr(gglc, name, set())

    def publish(day, run1="67.639"):
        pages[gglc.event_url(day)] = PAGE.format(run1=run1)

    def take_down(day):
        pages.pop(gglc.event_url(day), None)
        gglc._event_cache.clear()
        gglc._found.clear()

    def put(day, html):
        pages[gglc.event_url(day)] = html

    publish.take_down = take_down
    publish.put = put
    return publish


def test_past_event_outlives_its_page(client, gglc_site):
    gglc_site(PAST)
    assert gglc.list_events(2026) == [
        {"date": PAST.isoformat(), "url": gglc.event_url(PAST)}
    ]

    gglc_site.take_down(PAST)

    assert [e["date"] for e in gglc.list_events(2026)] == [PAST.isoformat()]
    event = client.get(f"/api/gglc/events/{PAST.isoformat()}").json()
    assert event["classes"][0]["drivers"][0]["best"] == 59.016


def test_todays_event_is_saved_but_still_refetched(client, gglc_site):
    gglc_site(TODAY, run1="60.000")
    assert (
        gglc.fetch_event(TODAY)["classes"][0]["drivers"][0]["runs"][0]["time"] == 60.0
    )

    gglc_site(TODAY, run1="58.000")
    assert (
        gglc.fetch_event(TODAY)["classes"][0]["drivers"][0]["runs"][0]["time"] == 58.0
    )

    gglc_site.take_down(TODAY)
    assert (
        gglc.fetch_event(TODAY)["classes"][0]["drivers"][0]["runs"][0]["time"] == 58.0
    )


# Every cell from "Run 1" on, which includes the page's Best column.
FULL = ["67.639", "59.016", "59.016"]
SHORT = ["59.016", "59.016"]


def _runs(event):
    return [run["raw"] for run in event["classes"][0]["drivers"][0]["runs"]]


def test_a_page_caught_mid_update_keeps_the_saved_results(client, gglc_site):
    gglc_site(PAST)
    gglc_site(TODAY)
    for day in (PAST, TODAY):
        gglc.fetch_event(day)

    # GGLC's page mid-upload: the title is there, the tables are not.
    for day in (PAST, TODAY):
        gglc_site.put(day, "<h1>GGLC Autocross Result</h1>")
        assert _runs(gglc.fetch_event(day)) == FULL
    assert [e["date"] for e in gglc.list_events(2026)] == [
        TODAY.isoformat(),
        PAST.isoformat(),
    ]


def test_a_shorter_page_wins_only_once_it_stays_short(client, gglc_site, monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(gglc, "time", SimpleNamespace(monotonic=lambda: clock[0]))
    gglc_site(TODAY)
    gglc.fetch_event(TODAY)

    gglc_site(TODAY, run1="")
    assert _runs(gglc.fetch_event(TODAY)) == FULL
    clock[0] += gglc.SHRINK_GRACE - 1
    assert _runs(gglc.fetch_event(TODAY)) == FULL
    clock[0] += 1
    assert _runs(gglc.fetch_event(TODAY)) == SHORT
    # The correction is saved, so it is what a later dropout falls back to.
    gglc_site.take_down(TODAY)
    assert _runs(gglc.fetch_event(TODAY)) == SHORT


def test_a_failed_probe_does_not_fail_the_list(client, gglc_site, monkeypatch):
    gglc_site(PAST)
    gglc.fetch_event(PAST)

    def down(request):
        raise httpx.ConnectError("GGLC is down")

    monkeypatch.setattr(
        gglc, "_http", httpx.Client(transport=httpx.MockTransport(down))
    )
    assert [e["date"] for e in gglc.list_events(2026)] == [PAST.isoformat()]
    # Days it couldn't ask about are asked again next time, not written off.
    assert gglc._missing == set()


def _cell(text, best=False):
    attrs = {"style": "background-color:lightgreen"} if best else {}
    return {"tag": "td", "attrs": attrs, "text": text}


def test_unhighlighted_row_scores_best_of_first_five():
    runs = [_cell(t) for t in ("40.5+1", "40.2", "dnf", "40.9", "40.4", "39.0")]
    gglc_pdf.mark_scored_run(runs)
    assert [i for i, c in enumerate(runs) if c["attrs"]] == [1]


def test_car_on_course_is_not_a_time():
    head = ("Name", "Indexed", "Run 1", "Run 2", "Run 3")
    klass = gglc._parse_table(
        [
            [{"tag": "th", "attrs": {}, "text": "Street"}],
            [{"tag": "th", "attrs": {}, "text": h} for h in head],
            [_cell("Will"), _cell("0.000"), _cell("52.1"), _cell("0.000"), _cell("")],
            [_cell("Ann"), _cell("0"), _cell("0.000+1"), _cell(""), _cell("")],
        ]
    )
    will, ann = klass["drivers"]
    assert [run["run"] for run in will["runs"]] == [1]
    assert will["best"] == 52.1
    assert will["indexed"] is None
    assert ann["runs"] == [] and ann["best"] is None and ann["indexed"] is None


def test_runs_are_numbered_past_empty_columns():
    # 2026-11-08: the morning block had Run 1-10 columns, most left blank,
    # then the afternoon block started again at Run 1.
    head = ("Name", "Indexed", "Run 1", "Run 2", "Run 3", "Run 1", "Run 2")
    klass = gglc._parse_table(
        [
            [{"tag": "th", "attrs": {}, "text": "Fun"}],
            [{"tag": "th", "attrs": {}, "text": h} for h in head],
            [
                _cell("Roman"),
                _cell("44.119"),
                _cell("46.445"),
                _cell("44.119", best=True),
                _cell(""),
                _cell("44.049"),
                _cell("43.780+1"),
            ],
        ]
    )
    (roman,) = klass["drivers"]
    assert [run["run"] for run in roman["runs"]] == [1, 2, 3, 4]
    assert [run["column"] for run in roman["runs"]] == [1, 2, 4, 5]
    assert [run["raw"] for run in roman["runs"]][2:] == ["44.049", "43.780+1"]
    assert roman["official"] == 44.119


def test_highlight_wins_over_a_faster_run():
    runs = [_cell("38.493"), _cell("38.138"), _cell("38.385", best=True)]
    gglc_pdf.mark_scored_run(runs)
    assert [i for i, c in enumerate(runs) if c["attrs"]] == [2]


def test_right_hand_page_detection():
    def page(*firsts, meta=False):
        rows = [{"kind": "cells", "cells": [{"text": t}]} for t in firsts]
        return rows + ([{"kind": "meta", "text": "Updated 04:36PM"}] if meta else [])

    assert gglc_pdf.is_right_page(page("Run 5", "31.400", "dnf", ""))
    assert not gglc_pdf.is_right_page(page("Name", "Will", "", meta=True))
    assert not gglc_pdf.is_right_page(page("Will", "31.400"))
    assert not gglc_pdf.is_right_page(page("", ""))


def test_pdf_import_replaces_the_live_page(client, gglc_site, monkeypatch):
    gglc_site(PAST, run1="99.000")
    gglc.fetch_event(PAST)

    pdf_url = gglc_pdf.pdf_url(PAST)
    pdf_event = {
        "date": PAST.isoformat(),
        "url": pdf_url,
        "title": "GGLC Autocross Result",
        "updated": "04:36PM",
        "classes": [
            gglc._parse_table(
                [
                    [{"tag": "th", "attrs": {}, "text": "Lotus Elise"}],
                    [{"tag": "th", "attrs": {}, "text": h} for h in ("Name", "Run 1")],
                    [_cell("Will"), _cell("59.016", best=True)],
                ]
            )
        ],
    }
    real_get = gglc._http.get
    monkeypatch.setattr(
        gglc._http,
        "get",
        lambda url: (
            httpx.Response(200, content=b"%PDF", request=httpx.Request("GET", url))
            if url == pdf_url
            else real_get(url)
        ),
    )
    monkeypatch.setattr(gglc_pdf, "convert", lambda data, url: pdf_event)
    assert gglc_pdf.import_day(PAST).startswith("saved")

    gglc._event_cache.clear()
    event = client.get(f"/api/gglc/events/{PAST.isoformat()}").json()
    assert event["url"] == pdf_url
    assert event["classes"][0]["drivers"][0]["official"] == 59.016
