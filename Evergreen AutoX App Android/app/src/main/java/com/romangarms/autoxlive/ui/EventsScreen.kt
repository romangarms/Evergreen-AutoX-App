package com.romangarms.autoxlive.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.romangarms.autoxlive.AppState
import com.romangarms.autoxlive.AppViewModel
import com.romangarms.autoxlive.data.EventSource
import com.romangarms.autoxlive.data.SHEvent
import kotlinx.coroutines.launch

// Both sections must fit on one screen with the search field, so each shows
// only its newest few until expanded.
private const val COLLAPSED_COUNT = 5

private sealed interface EventRow {
    val key: String

    data class Month(val month: String) : EventRow {
        override val key get() = "month-$month"
    }

    data class Event(val event: SHEvent) : EventRow {
        override val key get() = "event-${event.id}"
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EventsScreen(vm: AppViewModel, state: AppState) {
    var search by rememberSaveable { mutableStateOf("") }
    var expanded by rememberSaveable { mutableStateOf(listOf<String>()) }
    var refreshing by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val query = search.trim()
    val searching = query.isNotEmpty()
    // Searching looks through everything; the toggle only shapes browsing.
    val autoXOnly = state.settings.speedhiveAutoXOnly && state.hasSpeedhiveAutoXEvents && !searching

    fun matches(event: SHEvent): Boolean {
        if (!searching) return !autoXOnly || AppState.isAutoX(event)
        return event.name.contains(query, ignoreCase = true) ||
            event.location?.name?.contains(query, ignoreCase = true) == true ||
            AppState.eventDate(event.startDate)?.contains(query, ignoreCase = true) == true
    }

    val sections = listOf(EventSource.GGLC, EventSource.SPEEDHIVE)
        .map { source -> source to state.events.filter { it.source == source && matches(it) } }
        .filter { it.second.isNotEmpty() }

    Column(Modifier.fillMaxSize()) {
        SearchField(search, onChange = { search = it })
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    vm.loadEvents()
                    refreshing = false
                }
            },
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(Modifier.fillMaxSize().animateContentSize()) {
                if (state.events.isEmpty()) {
                    item { EventsStatus(vm, state) }
                } else if (sections.isEmpty()) {
                    item {
                        EGText("No events match \"$query\".", 12f, color = EG.colors.grayDark, modifier = Modifier.padding(24.dp))
                    }
                }
                sections.forEachIndexed { index, (source, events) ->
                    if (index > 0) {
                        item(key = "divider-${source.name}") {
                            Box(
                                Modifier
                                    .padding(horizontal = 16.dp)
                                    .padding(top = 18.dp)
                                    .fillMaxWidth()
                                    .height(2.dp)
                                    .background(EG.colors.divider),
                            )
                        }
                    }
                    val isExpanded = source.name in expanded
                    eventSection(
                        vm = vm,
                        state = state,
                        source = source,
                        events = events,
                        searching = searching,
                        expanded = isExpanded,
                        onToggleExpanded = {
                            expanded = if (isExpanded) expanded - source.name else expanded + source.name
                        },
                    )
                }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }
}

private fun rows(events: List<SHEvent>, expanded: Boolean, searching: Boolean): List<EventRow> {
    val showAll = searching || expanded
    val shown = if (showAll) events else events.take(COLLAPSED_COUNT)
    if (!showAll || searching) return shown.map { EventRow.Event(it) }
    val rows = mutableListOf<EventRow>()
    var lastMonth: String? = null
    for (event in shown) {
        val month = AppState.eventMonth(event)
        if (month != null && month != lastMonth) {
            rows += EventRow.Month(month)
            lastMonth = month
        }
        rows += EventRow.Event(event)
    }
    return rows
}

private fun LazyListScope.eventSection(
    vm: AppViewModel,
    state: AppState,
    source: EventSource,
    events: List<SHEvent>,
    searching: Boolean,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
) {
    item(key = "header-${source.name}") {
        Column { SectionHeader(vm, state, source, events.size, searching, expanded, onToggleExpanded) }
    }
    items(rows(events, expanded, searching), key = { "${source.name}-${it.key}" }) { row ->
        when (row) {
            is EventRow.Month -> EGText(
                AppState.monthLabel(row.month).uppercase(),
                9.5f,
                weight = FontWeight.Black,
                tracking = 0.9f,
                color = EG.colors.gray,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .padding(top = 10.dp, bottom = 4.dp),
            )
            is EventRow.Event -> EventRowView(vm, state, row.event)
        }
    }
}

@Composable
private fun SectionHeader(
    vm: AppViewModel,
    state: AppState,
    source: EventSource,
    count: Int,
    searching: Boolean,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
) {
    val colors = EG.colors
    val expandable = !searching && count > COLLAPSED_COUNT
    // Speedhive's name is too long to share a row with its toggle and the
    // show-all button.
    val titleAbove = source == EventSource.SPEEDHIVE
    val title = @Composable {
        EGText(source.label.uppercase(), 12f, weight = FontWeight.Black, tracking = 1.1f, maxLines = 1)
    }
    if (titleAbove) {
        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 14.dp)) { title() }
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(top = if (titleAbove) 6.dp else 14.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (!titleAbove) title()
        Box(Modifier.weight(1f)) {
            if (source == EventSource.SPEEDHIVE && !searching && state.hasSpeedhiveAutoXEvents) {
                EGChipButton(onClick = { vm.setSpeedhiveAutoXOnly(!state.settings.speedhiveAutoXOnly) }) { style, tint ->
                    EGCheckbox(checked = state.settings.speedhiveAutoXOnly, size = 16f)
                    Text("AUTOX ONLY", style = style, color = tint, maxLines = 1)
                }
            } else {
                val detail = when (source) {
                    EventSource.SPEEDHIVE -> state.orgName
                    EventSource.GGLC -> "Golden Gate Lotus Club"
                    EventSource.LEADERBOARD -> null
                }
                if (detail != null) EGText(detail, 10.5f, color = colors.gray, maxLines = 1)
            }
        }
        if (expandable) {
            EGChipButton(onClick = onToggleExpanded, tint = colors.red) { style, tint ->
                Text(if (expanded) "SHOW LESS" else "SHOW ALL $count", style = style, color = tint, maxLines = 1)
                Icon(
                    if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(egDp(14f)),
                )
            }
        }
    }
}

@Composable
private fun EventRowView(vm: AppViewModel, state: AppState, event: SHEvent) {
    val colors = EG.colors
    val selected = event.id == state.selectedEventId
    Column(
        Modifier
            .fillMaxWidth()
            .background(if (selected) colors.meBg else Color.Transparent)
            .clickable { vm.openEvent(event.id) },
    ) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                // Most events share a name, so the date is what tells rows apart.
                EGText(AppState.eventDate(event.startDate) ?: event.name, 13.5f, weight = FontWeight.Black)
                val subtitle = subtitle(event)
                if (subtitle.isNotEmpty()) EGText(subtitle, 10.5f, color = colors.gray)
            }
            if (selected) {
                EGTag("SELECTED", size = 9f, modifier = Modifier.padding(end = 8.dp))
            } else if (event.id == state.latestAutoXEventId) {
                EGTag("LATEST", background = colors.ink, foreground = colors.bg, size = 9f, modifier = Modifier.padding(end = 8.dp))
            }
            Icon(
                Icons.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = if (colors.dark) Color(0xFF757070) else Color(0xFF9B9797),
                modifier = Modifier.size(egDp(18f)),
            )
        }
    }
}

private fun subtitle(event: SHEvent): String {
    val dated = AppState.eventDate(event.startDate) != null
    return when (event.source) {
        EventSource.LEADERBOARD -> ""
        EventSource.GGLC -> if (dated) event.name else ""
        EventSource.SPEEDHIVE -> listOfNotNull(if (dated) event.name else null, event.location?.name).joinToString(" · ")
    }
}

@Composable
internal fun SearchField(value: String, onChange: (String) -> Unit, placeholder: String = "Search events") {
    val colors = EG.colors
    Row(
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .padding(top = 10.dp)
            .fillMaxWidth()
            .defaultMinSize(minHeight = 36.dp)
            .background(colors.card)
            .border(1.dp, colors.divider, RectangleShape)
            .padding(horizontal = 9.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = colors.gray, modifier = Modifier.size(egDp(16f)))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) EGText(placeholder, 12.5f, color = colors.gray, maxLines = 1)
            BasicTextField(
                value = value,
                onValueChange = onChange,
                singleLine = true,
                textStyle = egStyle(12.5f).copy(color = colors.ink),
                cursorBrush = SolidColor(colors.red),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (value.isNotEmpty()) {
            Icon(
                Icons.Filled.Cancel,
                contentDescription = "Clear search",
                tint = colors.gray,
                modifier = Modifier
                    .size(28.dp)
                    .clickable { onChange("") }
                    .padding(4.dp),
            )
        }
    }
}

@Composable
private fun EventsStatus(vm: AppViewModel, state: AppState) {
    val colors = EG.colors
    Column(
        Modifier.fillMaxWidth().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        when {
            state.isLoading -> {
                androidx.compose.material3.CircularProgressIndicator(color = colors.red)
                EGText("Loading timing data…", 12f, color = colors.grayDark)
            }
            state.errorMessage != null -> {
                EGTag("OFFLINE", background = colors.darkRed)
                EGText(state.errorMessage, 12f, color = colors.grayDark)
                EGText("Check your connection and try again.", 11f, color = colors.gray)
                EGButton("RETRY", onClick = { vm.refreshEvents() }, kind = EGButtonKind.PRIMARY)
            }
            else -> EGText("No events found.", 12f, color = colors.grayDark)
        }
    }
}
