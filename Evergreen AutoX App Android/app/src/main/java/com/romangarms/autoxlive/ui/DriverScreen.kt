package com.romangarms.autoxlive.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.romangarms.autoxlive.AppState
import com.romangarms.autoxlive.AppViewModel
import com.romangarms.autoxlive.data.Driver
import com.romangarms.autoxlive.data.LapTime
import com.romangarms.autoxlive.data.Run
import java.util.Locale

data class EGStat(val label: String, val value: String, val color: Color)

@Composable
fun DriverScreen(vm: AppViewModel, state: AppState, number: String, openCompare: (String, String) -> Unit) {
    val driver = state.driver(number)
    if (driver == null) {
        EGPullable { MissingDriver(vm, state) }
        return
    }
    val colors = EG.colors
    val nickname = state.nicknames[driver.startNumber]
    val isMe = driver.startNumber == state.meNumber
    var pickingMe by rememberSaveable { mutableStateOf(false) }

    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        item {
            Column(Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    EGText(nickname ?: driver.name, 24f, weight = FontWeight.Black, maxLines = 2, modifier = Modifier.weight(1f, fill = false))
                    if (isMe) EGTag("ME", background = colors.ink, foreground = colors.bg, size = 9f)
                    if (driver.startNumber in state.pins) {
                        Icon(Icons.Filled.Star, contentDescription = "Pinned", tint = colors.red, modifier = Modifier.size(egDp(15f)))
                    }
                }
                if (nickname != null) EGText(driver.name, 12f, color = colors.grayDark)
                driver.vehicle?.let { EGText(it, 14f, weight = FontWeight.SemiBold, color = colors.grayDark) }
                Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    driver.carClass?.let { EGTag(it, size = 10f) }
                    EGOutlineTag("CAR #${driver.startNumber}")
                }
            }
        }
        item {
            EGStatsGrid(driverStats(state, driver), Modifier.padding(top = 14.dp))
        }
        if (!isMe) {
            item {
                EGButton(
                    "COMPARE VS ME",
                    onClick = {
                        val me = state.me
                        if (me != null) openCompare(me.startNumber, driver.startNumber) else pickingMe = true
                    },
                    kind = EGButtonKind.PRIMARY,
                    modifier = Modifier.padding(top = 14.dp),
                )
            }
        }
        if (driver.timedRuns.isNotEmpty()) {
            item { DriverTimesChart(driver, Modifier.padding(top = 14.dp)) }
        }
        item { Box(Modifier.height(14.dp)) }
        driverRunsTable(driver, runDetail = { run -> if (run.number == driver.officialRunNumber) "OFFICIAL BEST" else null })
        item { Box(Modifier.height(24.dp)) }
    }

    if (pickingMe) {
        PickMeSheet(
            state = state,
            target = driver,
            onDismiss = { pickingMe = false },
            onPick = { candidate ->
                vm.setMe(candidate.startNumber)
                pickingMe = false
                if (candidate.startNumber != driver.startNumber) openCompare(candidate.startNumber, driver.startNumber)
            },
        )
    }
}

@Composable
private fun driverStats(state: AppState, driver: Driver): List<List<EGStat>> {
    val colors = EG.colors
    val classCount = state.classCount(driver.carClass)
    val rows = mutableListOf(
        listOf(
            EGStat("BEST", driver.bestString, colors.red),
            EGStat("IN CLASS", driver.positionInClass?.let { "P$it / $classCount" } ?: "—", colors.ink),
            EGStat("OVERALL", "P${driver.position} / ${state.drivers.size}", colors.ink),
        ),
        listOf(
            EGStat("AVERAGE", driver.average?.let(LapTime::format) ?: "—", colors.ink),
            EGStat("SPREAD", driver.spread?.let { String.format(Locale.US, "%.2fs", it) } ?: "—", colors.ink),
            EGStat("RUNS", "${driver.runs.size}", colors.ink),
        ),
    )
    val official = driver.officialBest
    val officialNumber = driver.officialRunNumber
    if (official != null && officialNumber != null) {
        rows += listOf(EGStat("OFFICIAL BEST (R$officialNumber, GGLC SCORED)", LapTime.format(official), colors.ink))
    }
    return rows
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickMeSheet(state: AppState, target: Driver, onDismiss: () -> Unit, onPick: (Driver) -> Unit) {
    val colors = EG.colors
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.bg) {
        LazyColumn {
            item {
                Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    EGText("Which driver is you?", 18f, weight = FontWeight.Black)
                    EGText(
                        "Tap yourself to compare with ${state.displayName(target)}. Change it later from the ⋮ menu on any driver.",
                        12f,
                        color = colors.grayDark,
                    )
                }
            }
            items(state.drivers, key = { it.startNumber + "-" + it.position }) { candidate ->
                Column(Modifier.fillMaxWidth().clickable { onPick(candidate) }) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
                    Row(
                        Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        EGText("P${candidate.position}", 13f, weight = FontWeight.Black, modifier = Modifier.egWidth(34f))
                        Column(Modifier.weight(1f)) {
                            EGText(state.displayName(candidate), 13.5f, weight = FontWeight.Black, maxLines = 1)
                            EGText(
                                listOfNotNull("#${candidate.startNumber}", candidate.carClass).joinToString(" · "),
                                10.5f,
                                color = colors.gray,
                                maxLines = 1,
                            )
                        }
                        EGText(candidate.bestString, 13f, weight = FontWeight.Bold, modifier = Modifier, maxLines = 1)
                    }
                }
            }
            item { Box(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun MissingDriver(vm: AppViewModel, state: AppState) {
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
                EGText("Check your connection and try again.", 11f, color = colors.gray)
                EGButton("RETRY", onClick = { vm.reload() }, kind = EGButtonKind.PRIMARY)
            }
            else -> EGText("This driver isn't in this session.", 12f, color = colors.grayDark)
        }
    }
}

@Composable
fun EGStatsGrid(rows: List<List<EGStat>>, modifier: Modifier = Modifier) {
    val colors = EG.colors
    Column(modifier.fillMaxWidth().border(2.dp, colors.divider, RectangleShape)) {
        rows.forEachIndexed { index, stats ->
            if (index > 0) Box(Modifier.fillMaxWidth().height(2.dp).background(colors.divider))
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
                stats.forEachIndexed { i, stat ->
                    if (i > 0) Box(Modifier.width(2.dp).fillMaxHeight().background(colors.divider))
                    Column(
                        Modifier.weight(1f).padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        EGColumnLabel(stat.label, size = 9f)
                        Text(
                            stat.value,
                            style = egStyle(16f, FontWeight.Black).copy(fontFeatureSettings = "tnum"),
                            color = stat.color,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

class RunMenuItem(val label: String, val destructive: Boolean = false, val action: () -> Unit)

fun LazyListScope.driverRunsTable(
    driver: Driver,
    runDetail: ((Run) -> String?)? = null,
    menu: ((Run) -> List<RunMenuItem>)? = null,
) {
    val showsSpeed = driver.runs.any { it.speed != null }
    stickyHeader(key = "runs-header") {
        Row(
            Modifier
                .fillMaxWidth()
                .background(EG.colors.bg)
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            EGColumnLabel("RUN", Modifier.egWidth(44f))
            EGColumnLabel("TIME", Modifier.weight(1f))
            if (showsSpeed) RightLabel("MPH", 52f)
            RightLabel("Δ BEST", 66f)
            if (menu != null) Box(Modifier.width(30.dp))
        }
    }
    if (driver.runs.isEmpty()) {
        item(key = "runs-empty") {
            EGText("No runs recorded yet.", 12f, color = EG.colors.grayDark, modifier = Modifier.padding(vertical = 8.dp))
        }
    }
    items(driver.runs, key = { "run-${it.id}" }) { run ->
        RunRow(driver, run, showsSpeed, runDetail?.invoke(run), menu?.invoke(run))
    }
}

@Composable
private fun RightLabel(text: String, width: Float) {
    Box(Modifier.egWidth(width), contentAlignment = Alignment.CenterEnd) { EGColumnLabel(text) }
}

@Composable
private fun RunRow(driver: Driver, run: Run, showsSpeed: Boolean, runDetail: String?, menuItems: List<RunMenuItem>?) {
    val colors = EG.colors
    val isBest = !run.dnf && run.seconds == driver.best
    val cones = when (run.cones) {
        0 -> null
        1 -> "+1 cone"
        else -> "+${run.cones} cones"
    }
    val detail = listOfNotNull(runDetail, cones).takeIf { it.isNotEmpty() }?.joinToString(" · ")
    val delta = when {
        driver.best == null || run.dnf -> ""
        isBest -> "BEST"
        else -> "+" + String.format(Locale.US, "%.3f", run.seconds - driver.best!!)
    }
    Column(Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
        Column(
            Modifier
                .fillMaxWidth()
                .background(if (isBest) colors.pinnedBg else Color.Transparent)
                .padding(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                EGText("R${run.number}", 12f, weight = FontWeight.Black, modifier = Modifier.egWidth(44f).padding(start = if (isBest) 6.dp else 0.dp))
                Text(
                    run.timeString,
                    style = egStyle(13f, if (isBest) FontWeight.Black else FontWeight.Normal).copy(fontFeatureSettings = "tnum"),
                    color = when {
                        isBest -> colors.red
                        run.dnf -> colors.gray
                        else -> colors.ink
                    },
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
                if (showsSpeed) {
                    Text(
                        run.speed?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                        style = egStyle(12f).copy(fontFeatureSettings = "tnum"),
                        color = colors.grayDark,
                        textAlign = TextAlign.End,
                        modifier = Modifier.egWidth(52f),
                        maxLines = 1,
                    )
                }
                Text(
                    delta,
                    style = egStyle(12f, if (isBest) FontWeight.Black else FontWeight.Normal).copy(fontFeatureSettings = "tnum"),
                    color = if (isBest) colors.red else colors.gray,
                    textAlign = TextAlign.End,
                    modifier = Modifier.egWidth(66f).padding(end = if (isBest && menuItems == null) 6.dp else 0.dp),
                    maxLines = 1,
                )
                if (menuItems != null) RunMenu(menuItems)
            }
            if (detail != null) {
                EGText(detail, 9.5f, color = colors.gray, maxLines = 1, modifier = Modifier.padding(start = if (isBest) 6.dp else 0.dp))
            }
        }
    }
}

@Composable
private fun RunMenu(items: List<RunMenuItem>) {
    var open by remember { mutableStateOf(false) }
    Box(Modifier.width(30.dp), contentAlignment = Alignment.CenterEnd) {
        if (items.isNotEmpty()) {
            Icon(
                Icons.Filled.MoreHoriz,
                contentDescription = "Run options",
                tint = EG.colors.gray,
                modifier = Modifier.size(28.dp).clickable { open = true }.padding(4.dp),
            )
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                items.forEach { item ->
                    DropdownMenuItem(
                        text = { Text(item.label, color = if (item.destructive) EG.colors.red else EG.colors.ink) },
                        onClick = {
                            open = false
                            item.action()
                        },
                    )
                }
            }
        }
    }
}
