package com.romangarms.autoxlive.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.romangarms.autoxlive.AppState
import com.romangarms.autoxlive.AppViewModel
import com.romangarms.autoxlive.data.Driver
import kotlinx.coroutines.launch

private fun digitsStyle(size: Float, weight: FontWeight = FontWeight.Normal): TextStyle =
    egStyle(size, weight).copy(fontFeatureSettings = "tnum")

private fun naturalCompare(a: String, b: String): Int {
    val pattern = Regex("\\d+|\\D+")
    val pa = pattern.findAll(a.lowercase()).map { it.value }.toList()
    val pb = pattern.findAll(b.lowercase()).map { it.value }.toList()
    for (i in 0 until minOf(pa.size, pb.size)) {
        val x = pa[i]
        val y = pb[i]
        val c = if (x[0].isDigit() && y[0].isDigit()) {
            x.toBigInteger().compareTo(y.toBigInteger())
        } else {
            x.compareTo(y)
        }
        if (c != 0) return c
    }
    return pa.size - pb.size
}

// Every word has to hit something, so "miata 12" or "tom ss" narrows down.
// Car numbers match from the start ("1" finds #1 and #12, not #21); the text
// fields match anywhere. Mirrors LiveView.matches on iOS.
internal fun matchesSearch(driver: Driver, nickname: String?, query: String): Boolean =
    query.split(Regex("\\s+")).filter { it.isNotEmpty() }.all { word ->
        val number = word.removePrefix("#")
        when {
            number.isEmpty() -> true
            driver.startNumber.startsWith(number, ignoreCase = true) -> true
            word.startsWith("#") -> false
            else -> listOfNotNull(driver.name, nickname, driver.vehicle, driver.carClass)
                .any { it.contains(word, ignoreCase = true) }
        }
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveScreen(vm: AppViewModel, state: AppState, openDriver: (String) -> Unit) {
    if (state.drivers.isEmpty()) {
        EGRefreshBox(vm::reloadResults) { EGPullable { StatusView(vm, state) } }
        return
    }
    var pickingMe by rememberSaveable { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val byClass = state.settings.liveSortByClass
    // A new session starts with an empty search, as on iOS.
    var search by rememberSaveable(state.selectedSessionId) { mutableStateOf("") }
    val query = search.trim()
    val drivers = if (query.isEmpty()) {
        state.drivers
    } else {
        state.drivers.filter { matchesSearch(it, state.nicknames[it.startNumber], query) }
    }

    Column(Modifier.fillMaxSize()) {
        if (pickingMe || state.showsMePrompt) {
            MePrompt(
                picking = pickingMe,
                onFind = { pickingMe = true },
                onCancel = { pickingMe = false },
                onDismiss = { vm.dismissMePrompt() },
            )
        }
        SearchField(search, onChange = { search = it }, placeholder = "Search car #, driver, car, class")
        ResultsColumnHeader()
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    vm.loadSessionData()
                    refreshing = false
                }
            },
            modifier = Modifier.weight(1f),
        ) {
            val onTap: (Driver) -> Unit = { driver ->
                if (pickingMe) {
                    vm.setMe(driver.startNumber)
                    pickingMe = false
                } else {
                    openDriver(driver.startNumber)
                }
            }
            LazyColumn(Modifier.fillMaxSize()) {
                if (drivers.isEmpty()) {
                    item(key = "no-match") {
                        EGText(
                            "No drivers match \"$query\".",
                            12f,
                            color = EG.colors.grayDark,
                            modifier = Modifier.padding(24.dp),
                        )
                    }
                } else if (byClass) {
                    val groups = drivers
                        .groupBy { it.carClass ?: "No class" }
                        .map { (name, drivers) ->
                            name to drivers.sortedWith(
                                compareBy<Driver>({ it.positionInClass ?: Int.MAX_VALUE }, { it.position }),
                            )
                        }
                        .sortedWith { a, b -> naturalCompare(a.first, b.first) }
                    groups.forEach { (name, drivers) ->
                        item(key = "class-$name") { ClassHeader(name, drivers.size) }
                        items(drivers, key = { "d-${it.position}" }) { driver ->
                            ResultRow(vm, state, driver, byClass = true, onTap = { onTap(driver) })
                        }
                    }
                } else {
                    items(drivers, key = { it.position }) { driver ->
                        ResultRow(vm, state, driver, onTap = { onTap(driver) })
                    }
                }
            }
        }
    }
}

@Composable
private fun ClassHeader(name: String, count: Int) {
    val colors = EG.colors
    Column(Modifier.fillMaxWidth().background(colors.meBg)) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.divider))
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            EGText(name.uppercase(), 11f, weight = FontWeight.Black, tracking = 0.9f, maxLines = 1)
            EGText(if (count == 1) "1 driver" else "$count drivers", 10f, color = colors.gray)
        }
    }
}

// Sits above the list so the instruction stays visible while scrolling a long
// field to find yourself.
@Composable
private fun MePrompt(picking: Boolean, onFind: () -> Unit, onCancel: () -> Unit, onDismiss: () -> Unit) {
    val colors = EG.colors
    Column(Modifier.fillMaxWidth().background(if (picking) colors.pinnedBg else colors.meBg)) {
        Row(
            modifier = Modifier
                .padding(start = 16.dp, end = if (picking) 16.dp else 4.dp)
                .padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f)) {
                EGText(if (picking) "Tap yourself in the list" else "Which driver is you?", 12.5f, weight = FontWeight.Black)
                EGText(
                    if (picking) "Change it later from the ⋮ menu on any driver." else "Get a ME tag and gaps to your friends.",
                    10.5f,
                    color = colors.grayDark,
                )
            }
            if (picking) {
                EGChipButton("CANCEL", onClick = onCancel)
            } else {
                EGChipButton("FIND ME", onClick = onFind, tint = colors.red)
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Filled.Close, contentDescription = "Dismiss", tint = colors.gray, modifier = Modifier.size(egDp(16f)))
                }
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.divider))
    }
}

@Composable
private fun ResultsColumnHeader(showsNumber: Boolean = true, showsPin: Boolean = true) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        EGColumnLabel("POS", Modifier.egWidth(34f))
        if (showsNumber) EGColumnLabel("NO.", Modifier.egWidth(40f))
        EGColumnLabel("DRIVER", Modifier.weight(1f))
        Box(Modifier.egWidth(70f), contentAlignment = Alignment.CenterEnd) { EGColumnLabel("BEST") }
        Spacer(Modifier.width(if (showsPin) 36.dp else 12.dp))
    }
}

@Composable
private fun StatusView(vm: AppViewModel, state: AppState, empty: String = "No results in this session yet.") {
    val colors = EG.colors
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when {
            state.isLoading -> {
                CircularProgressIndicator(color = colors.gray, modifier = Modifier.size(28.dp), strokeWidth = 3.dp)
                EGText("Loading timing data…", 12f, color = colors.grayDark)
            }
            state.errorMessage != null -> {
                EGTag("OFFLINE", background = colors.darkRed)
                Text(state.errorMessage, style = egStyle(12f), color = colors.grayDark, textAlign = TextAlign.Center)
                EGText("Check your connection and try again.", 11f, color = colors.gray)
                EGButton("RETRY", onClick = { vm.refreshEvents() }, kind = EGButtonKind.PRIMARY)
            }
            else -> EGText(empty, 12f, color = colors.grayDark)
        }
    }
}

@Composable
private fun ResultRow(
    vm: AppViewModel,
    state: AppState,
    driver: Driver,
    byClass: Boolean = false,
    onTap: () -> Unit,
) {
    val colors = EG.colors
    val pinned = driver.startNumber in state.pins
    val isMe = driver.startNumber == state.meNumber
    val nickname = state.nicknames[driver.startNumber]
    val subtitle = buildList {
        if (nickname != null) add(driver.name)
        if (byClass) add("P${driver.position} overall") else driver.carClass?.let { add(it) }
        driver.vehicle?.let { add(it) }
    }.joinToString(" · ")

    Column(
        Modifier
            .fillMaxWidth()
            .background(if (pinned) colors.pinnedBg else if (isMe) colors.meBg else colors.bg),
    ) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .clickable(onClick = onTap)
                    .padding(start = 16.dp, end = 8.dp, top = 9.dp, bottom = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val position = if (byClass) driver.positionInClass ?: driver.position else driver.position
                EGText("P$position", 14f, weight = FontWeight.Black, maxLines = 1, modifier = Modifier.egWidth(34f))
                Text(
                    "#${driver.startNumber}",
                    style = digitsStyle(12f),
                    color = colors.gray,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.egWidth(40f),
                )
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        EGText(
                            state.displayName(driver),
                            13f,
                            weight = FontWeight.Black,
                            maxLines = 1,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        if (isMe) EGTag("ME", background = colors.ink, foreground = colors.bg, size = 8.5f)
                    }
                    if (subtitle.isNotEmpty()) EGText(subtitle, 10f, color = colors.gray, maxLines = 1)
                }
                Column(Modifier.egWidth(70f), horizontalAlignment = Alignment.End) {
                    Text(driver.bestString, style = digitsStyle(14f, FontWeight.Black), color = colors.ink, maxLines = 1)
                    EGText(if (driver.runs.size == 1) "1 run" else "${driver.runs.size} runs", 9.5f, color = colors.gray, maxLines = 1)
                }
            }
            IconButton(onClick = { vm.togglePin(driver.startNumber) }, modifier = Modifier.padding(end = 6.dp)) {
                Icon(
                    if (pinned) Icons.Filled.Star else Icons.Filled.StarBorder,
                    contentDescription = if (pinned) "Unpin" else "Pin",
                    tint = if (pinned) colors.red else colors.gray,
                    modifier = Modifier.size(egDp(22f)),
                )
            }
        }
    }
}
