from datetime import date

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
    for name in ("_event_cache", "_saved"):
        monkeypatch.setattr(gglc, name, {})
    for name in ("_found", "_missing"):
        monkeypatch.setattr(gglc, name, set())

    def publish(day, run1="67.639"):
        pages[gglc.event_url(day)] = PAGE.format(run1=run1)

    def take_down(day):
        pages.pop(gglc.event_url(day), None)
        gglc._event_cache.clear()
        gglc._found.clear()

    publish.take_down = take_down
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
