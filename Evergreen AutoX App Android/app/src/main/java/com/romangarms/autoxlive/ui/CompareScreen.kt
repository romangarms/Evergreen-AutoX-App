package com.romangarms.autoxlive.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.romangarms.autoxlive.AppState
import com.romangarms.autoxlive.AppViewModel
import com.romangarms.autoxlive.data.Driver
import com.romangarms.autoxlive.data.LapTime
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

@Composable
fun CompareScreen(vm: AppViewModel, state: AppState, a: String, b: String) {
    val driverA = state.driver(a)
    val driverB = state.driver(b)
    if (driverA == null || driverB == null) {
        EGPullable { MissingCompare(vm, state) }
        return
    }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(top = 14.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Names(state, driverA, driverB)
        StatGrid(driverA, driverB)
        ChartSection(state, driverA, driverB)
        RunByRun(driverA, driverB)
    }
}

@Composable
private fun Names(state: AppState, a: Driver, b: Driver) {
    val colors = EG.colors
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            EGText("#${a.startNumber} · ${a.carClass ?: "—"}", 10f, weight = FontWeight.Black, tracking = 0.9f, color = colors.red, maxLines = 1)
            EGText(state.displayName(a), 16f, weight = FontWeight.Black, maxLines = 2)
        }
        EGText("VS", 12f, weight = FontWeight.Black, color = colors.gray, modifier = Modifier.padding(bottom = 2.dp))
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
            EGColumnLabel("#${b.startNumber} · ${b.carClass ?: "—"}", size = 10f)
            Text(
                state.displayName(b),
                style = egStyle(16f, FontWeight.Black),
                color = colors.ink,
                textAlign = TextAlign.End,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private class CompareStat(val label: String, val a: Double?, val b: Double?, val format: (Double) -> String)

@Composable
private fun StatGrid(a: Driver, b: Driver) {
    val colors = EG.colors
    val rows = listOf(
        CompareStat("BEST", a.best, b.best, LapTime::format),
        CompareStat("AVERAGE", a.average, b.average, LapTime::format),
        CompareStat("SPREAD", a.spread, b.spread) { String.format(Locale.US, "%.2fs", it) },
        CompareStat("RUNS", a.runs.size.toDouble(), b.runs.size.toDouble()) { it.toInt().toString() },
    )
    Column(Modifier.fillMaxWidth().border(2.dp, colors.divider, RectangleShape)) {
        rows.forEachIndexed { index, row ->
            if (index > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
            val aWins = wins(row.a, row.b)
            val bWins = wins(row.b, row.a)
            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    row.a?.let(row.format) ?: "—",
                    style = egStyle(12.5f, if (aWins) FontWeight.Black else FontWeight.Normal).copy(fontFeatureSettings = "tnum"),
                    color = if (aWins) colors.red else colors.ink,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
                EGColumnLabel(row.label)
                Text(
                    row.b?.let(row.format) ?: "—",
                    style = egStyle(12.5f, if (bWins) FontWeight.Black else FontWeight.Normal).copy(fontFeatureSettings = "tnum"),
                    color = if (bWins) colors.red else colors.ink,
                    textAlign = TextAlign.End,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
            }
        }
    }
}

private fun wins(value: Double?, other: Double?): Boolean = value != null && other != null && value < other

@Composable
private fun ChartSection(state: AppState, a: Driver, b: Driver) {
    val colors = EG.colors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            EGColumnLabel("TIMES OVER THE DAY", Modifier.weight(1f))
            LegendItem(colors.red, state.displayName(a), Modifier.weight(1f, fill = false))
            LegendItem(colors.ink, state.displayName(b), Modifier.weight(1f, fill = false))
        }
        if (a.timedRuns.isEmpty() && b.timedRuns.isEmpty()) {
            EGText("No runs to chart yet.", 12f, color = colors.grayDark)
        } else {
            RunChart(a, b)
        }
    }
}

@Composable
private fun LegendItem(color: Color, name: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.width(14.dp).height(2.dp).background(color))
        EGText(name, 9.5f, weight = FontWeight.Black, color = EG.colors.gray, maxLines = 1)
    }
}

private fun niceTicks(lo: Double, hi: Double, desired: Int): List<Double> {
    val span = hi - lo
    if (span <= 0) return listOf(lo)
    val raw = span / desired
    val magnitude = 10.0.pow(floor(log10(raw)))
    val step = listOf(1.0, 2.0, 2.5, 5.0, 10.0).map { it * magnitude }.first { it >= raw }
    val ticks = mutableListOf<Double>()
    var tick = ceil(lo / step) * step
    while (tick <= hi + step * 1e-9) {
        ticks += tick
        tick += step
    }
    return ticks
}

/** The driver page's "times over the day" chart: the compare chart with one driver. */
@Composable
fun DriverTimesChart(driver: Driver, modifier: Modifier = Modifier) {
    if (driver.timedRuns.isEmpty()) return
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        EGColumnLabel("TIMES OVER THE DAY")
        RunChart(driver, null)
    }
}

@Composable
private fun RunChart(a: Driver, b: Driver?) {
    val colors = EG.colors
    val measurer = rememberTextMeasurer()
    val labelStyle = egStyle(8.5f, FontWeight.Black).copy(color = colors.gray)
    val axisStyle = egStyle(8.5f, FontWeight.Bold).copy(color = colors.gray)

    val all = (a.timedRuns + b?.timedRuns.orEmpty()).map { it.seconds }
    val lo = all.minOrNull() ?: 0.0
    val hi = all.maxOrNull() ?: 1.0
    val pad = max((hi - lo) * 0.18, 0.25)
    val yMin = lo - pad
    val yMax = hi + pad
    val runCount = max(max(a.runs.size, b?.runs?.size ?: 0), 1)
    val ticks = niceTicks(yMin, yMax, 3)

    Canvas(Modifier.fillMaxWidth().height(egDp(140f))) {
        val yLabels = ticks.map { measurer.measure(String.format(Locale.US, "%.1f", it), axisStyle) }
        // A lone driver's own run numbers label the slots, so they match the runs
        // table; a comparison counts slots, like its run-by-run list.
        val xLabels = (1..runCount).map { slot ->
            val number = if (b == null) a.runs.getOrNull(slot - 1)?.number ?: slot else slot
            measurer.measure("R$number", labelStyle)
        }
        val leftInset = (yLabels.maxOfOrNull { it.size.width } ?: 0) + 6.dp.toPx()
        val bottomInset = (xLabels.maxOfOrNull { it.size.height } ?: 0) + 4.dp.toPx()
        val plotWidth = size.width - leftInset
        val plotHeight = size.height - bottomInset
        val xInset = 8.dp.toPx()

        fun x(run: Int): Float =
            if (runCount == 1) {
                leftInset + plotWidth / 2
            } else {
                leftInset + xInset + (plotWidth - 2 * xInset) * (run - 1) / (runCount - 1)
            }

        fun y(seconds: Double): Float = (plotHeight * (1 - (seconds - yMin) / (yMax - yMin))).toFloat()

        ticks.forEachIndexed { i, tick ->
            val ty = y(tick)
            drawLine(colors.hairline, Offset(leftInset, ty), Offset(size.width, ty), strokeWidth = 1.dp.toPx())
            val label = yLabels[i]
            drawText(label, topLeft = Offset(0f, ty - label.size.height / 2f))
        }
        xLabels.forEachIndexed { i, label ->
            drawText(label, topLeft = Offset(x(i + 1) - label.size.width / 2f, plotHeight + 4.dp.toPx()))
        }

        series(a, colors.red, null, ::x, ::y)
        if (b != null) series(b, colors.ink, PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 3.dp.toPx())), ::x, ::y)
    }
}

private fun DrawScope.series(
    driver: Driver,
    color: Color,
    dash: PathEffect?,
    x: (Int) -> Float,
    y: (Double) -> Float,
) {
    // Placed by order in the run list, not by run number: run numbers can skip
    // (laps filtered out as grid laps keep their numbers).
    val points = driver.runs.mapIndexedNotNull { i, run -> if (run.dnf) null else Offset(x(i + 1), y(run.seconds)) }
    if (points.size > 1) {
        val path = Path()
        points.forEachIndexed { i, point ->
            if (i == 0) path.moveTo(point.x, point.y) else path.lineTo(point.x, point.y)
        }
        drawPath(path, color, style = Stroke(width = 2.dp.toPx(), pathEffect = dash))
    }
    val side = 6.dp.toPx()
    points.forEach { point ->
        drawRect(color, topLeft = Offset(point.x - side / 2, point.y - side / 2), size = Size(side, side))
    }
}

@Composable
private fun RunByRun(a: Driver, b: Driver) {
    val colors = EG.colors
    Column {
        Row(Modifier.padding(bottom = 6.dp)) {
            EGColumnLabel("RUN-BY-RUN", Modifier.weight(1f))
            EGColumnLabel("GAP")
        }
        for (index in 0 until max(a.runs.size, b.runs.size)) {
            val runA = a.runs.getOrNull(index)
            val runB = b.runs.getOrNull(index)
            val gap = if (runA != null && runB != null && !runA.dnf && !runB.dnf) runA.seconds - runB.seconds else null
            val aFaster = (gap ?: 0.0) < 0
            val bFaster = (gap ?: 0.0) > 0
            Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
            Row(
                Modifier.padding(vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                EGText("R${index + 1}", 11f, weight = FontWeight.Black, color = colors.gray, modifier = Modifier.egWidth(22f), maxLines = 1)
                Text(
                    runA?.timeString ?: "—",
                    style = timeStyle(aFaster),
                    color = if (aFaster) colors.red else colors.ink,
                    modifier = Modifier.egWidth(62f),
                    maxLines = 1,
                )
                GapBar(gap, Modifier.weight(1f))
                Text(
                    runB?.timeString ?: "—",
                    style = timeStyle(bFaster),
                    color = if (bFaster) colors.red else colors.ink,
                    textAlign = TextAlign.End,
                    modifier = Modifier.egWidth(62f),
                    maxLines = 1,
                )
                Text(
                    gap?.let(LapTime::gap) ?: "—",
                    style = egStyle(11f).copy(fontFeatureSettings = "tnum"),
                    color = colors.grayDark,
                    textAlign = TextAlign.End,
                    modifier = Modifier.egWidth(48f),
                    maxLines = 1,
                )
            }
        }
    }
}

private fun timeStyle(bold: Boolean): TextStyle =
    egStyle(13f, if (bold) FontWeight.Black else FontWeight.Normal).copy(fontFeatureSettings = "tnum")

@Composable
private fun GapBar(gap: Double?, modifier: Modifier = Modifier) {
    val colors = EG.colors
    BoxWithConstraints(modifier.height(8.dp).background(colors.meBg)) {
        val width = maxWidth
        if (gap != null) {
            val fraction = (min(abs(gap) / 2.5, 1.0) * 0.5).toFloat()
            Box(
                Modifier
                    .offset(x = if (gap < 0) width * (0.5f - fraction) else width * 0.5f)
                    .width(width * fraction)
                    .height(8.dp)
                    .background(colors.red),
            )
        }
        Box(
            Modifier
                .offset(x = width * 0.5f - 1.dp)
                .width(2.dp)
                .height(8.dp)
                .background(colors.divider),
        )
    }
}

@Composable
private fun MissingCompare(vm: AppViewModel, state: AppState) {
    val colors = EG.colors
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
    ) {
        when {
            state.isLoading -> {
                CircularProgressIndicator(color = colors.red)
                EGText("Loading timing data…", 12f, color = colors.grayDark)
            }
            state.errorMessage != null -> {
                EGTag("OFFLINE", background = colors.darkRed)
                EGText(state.errorMessage, 12f, color = colors.grayDark)
                EGButton("RETRY", onClick = { vm.reload() }, kind = EGButtonKind.PRIMARY)
            }
            else -> EGText("One of these drivers isn't in this session.", 12f, color = colors.grayDark)
        }
    }
}
