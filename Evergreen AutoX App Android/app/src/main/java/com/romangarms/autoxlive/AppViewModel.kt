package com.romangarms.autoxlive

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.romangarms.autoxlive.data.AccelEntry
import com.romangarms.autoxlive.data.ApiClient
import com.romangarms.autoxlive.data.ApiException
import com.romangarms.autoxlive.data.Driver
import com.romangarms.autoxlive.data.EventSource
import com.romangarms.autoxlive.data.GGLCEventStub
import com.romangarms.autoxlive.data.LBBlock
import com.romangarms.autoxlive.data.LBCourse
import com.romangarms.autoxlive.data.LBCourseDetail
import com.romangarms.autoxlive.data.LBReportTarget
import com.romangarms.autoxlive.data.LBReportType
import com.romangarms.autoxlive.data.SHEvent
import com.romangarms.autoxlive.data.SHLocation
import com.romangarms.autoxlive.data.SHOrg
import com.romangarms.autoxlive.data.SHSession
import com.romangarms.autoxlive.data.Saved
import com.romangarms.autoxlive.data.SettingsStore
import com.romangarms.autoxlive.data.StoredSettings
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.util.Locale

interface AutoXApi {
    suspend fun org(orgId: Int): SHOrg
    suspend fun events(orgId: Int, limit: Int = 200): List<SHEvent>
    suspend fun sessions(eventId: Int): List<SHSession>
    suspend fun drivers(sessionId: Int): List<Driver>
    suspend fun gglcEvents(year: Int): List<GGLCEventStub>
    suspend fun leaderboardCourses(): List<LBCourse>
    suspend fun leaderboardCourse(id: Int): LBCourseDetail
    suspend fun acceleration(): List<AccelEntry>
    suspend fun joinCourse(code: String): LBCourse
    suspend fun leaveCourse(id: Int)
    suspend fun report(target: LBReportTarget, reason: String)
    suspend fun block(target: LBReportTarget): LBBlock
    suspend fun blocks(): List<LBBlock>
    suspend fun unblock(id: Int)

    // Runs `load` against the answers the server gave last time instead of
    // the server; null when they don't cover it.
    suspend fun <T> fromCache(load: suspend AutoXApi.() -> T): Saved<T>? = null
}

class RemoteApi(private val client: ApiClient) : AutoXApi {
    override suspend fun org(orgId: Int) = client.org(orgId)
    override suspend fun events(orgId: Int, limit: Int) = client.events(orgId, limit)
    override suspend fun sessions(eventId: Int) = client.sessions(eventId)
    override suspend fun drivers(sessionId: Int) = client.drivers(sessionId)
    override suspend fun gglcEvents(year: Int) = client.gglcEvents(year)
    override suspend fun leaderboardCourses() = client.leaderboardCourses()
    override suspend fun leaderboardCourse(id: Int) = client.leaderboardCourse(id)
    override suspend fun acceleration() = client.acceleration()
    override suspend fun joinCourse(code: String) = client.joinCourse(code)
    override suspend fun leaveCourse(id: Int) { client.leaveCourse(id) }
    override suspend fun report(target: LBReportTarget, reason: String) { client.report(target, reason) }
    override suspend fun block(target: LBReportTarget) = client.block(target)
    override suspend fun blocks() = client.blocks()
    override suspend fun unblock(id: Int) { client.unblock(id) }
    override suspend fun <T> fromCache(load: suspend AutoXApi.() -> T) = client.fromCache { RemoteApi(this).load() }
}

sealed interface NavCommand {
    data object ShowLive : NavCommand
    data class OpenLeaderboard(val courseId: Int) : NavCommand

    // Leaves the board's pages if one is open, landing on the Boards tab.
    data class LeaveLeaderboard(val courseId: Int) : NavCommand

    // Pops back to the board itself, since ranks may have moved under an
    // open driver page.
    data class BackToLeaderboard(val courseId: Int) : NavCommand
    data object BackToAcceleration : NavCommand
}

class AppViewModel(
    private val api: AutoXApi,
    private val store: SettingsStore,
    private val today: () -> LocalDate = LocalDate::now,
) : ViewModel() {
    private val _state = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = _state.asStateFlow()

    private val navChannel = Channel<NavCommand>(Channel.BUFFERED)
    val navCommands = navChannel.receiveAsFlow()

    var lastSessionLoad: Long = 0
        private set

    private val current get() = _state.value

    fun start() {
        if (current.loaded) return
        viewModelScope.launch {
            val settings = store.load()
            _state.update { it.copy(settings = settings, loaded = true) }
            loadEvents()
        }
    }

    private fun editSettings(change: (StoredSettings) -> StoredSettings) {
        _state.update { it.copy(settings = change(it.settings)) }
        val snapshot = current.settings
        viewModelScope.launch { store.save(snapshot) }
    }

    fun setRoute(route: RouteKind) {
        _state.update { it.copy(route = route) }
    }

    fun setLiveSortByClass(byClass: Boolean) = editSettings { it.copy(liveSortByClass = byClass) }
    fun setSpeedhiveAutoXOnly(only: Boolean) = editSettings { it.copy(speedhiveAutoXOnly = only) }
    fun acceptGuidelines() = editSettings { it.copy(acceptedGuidelines = true) }
    fun setLastUpdateCheck(millis: Long) = editSettings { it.copy(lastUpdateCheck = millis) }

    fun setMe(number: String?) {
        val key = current.eventKey ?: return
        editSettings {
            it.copy(meNumberByEvent = if (number == null) it.meNumberByEvent - key else it.meNumberByEvent + (key to number))
        }
    }

    fun dismissMePrompt() {
        val key = current.eventKey ?: return
        if (key in current.settings.mePromptDismissedEvents) return
        editSettings { it.copy(mePromptDismissedEvents = it.mePromptDismissedEvents + key) }
    }

    fun togglePin(number: String) {
        val key = current.eventKey ?: return
        val pins = current.pins.let { if (number in it) it - number else it + number }
        editSettings {
            it.copy(pinsByEvent = if (pins.isEmpty()) it.pinsByEvent - key else it.pinsByEvent + (key to pins.sorted()))
        }
        _state.update { s -> s.copy(compareSelection = s.compareSelection.filter { it in s.pins || it == s.meNumber }) }
    }

    fun toggleCompareSelection(number: String) {
        _state.update { s ->
            val selection = if (number in s.compareSelection) s.compareSelection - number else (s.compareSelection + number).takeLast(2)
            s.copy(compareSelection = selection)
        }
    }

    fun setNickname(nickname: String, number: String) {
        val key = current.eventKey ?: return
        val trimmed = nickname.trim()
        val names = current.nicknames.let { if (trimmed.isEmpty()) it - number else it + (number to trimmed) }
        editSettings {
            it.copy(nicknamesByEvent = if (names.isEmpty()) it.nicknamesByEvent - key else it.nicknamesByEvent + (key to names))
        }
    }

    fun resetPersonalization() {
        editSettings {
            it.copy(
                pinsByEvent = emptyMap(),
                nicknamesByEvent = emptyMap(),
                meNumberByEvent = emptyMap(),
                mePromptDismissedEvents = emptyList(),
            )
        }
        _state.update { it.copy(compareSelection = emptyList()) }
    }

    // Asks the server, or when it can't be reached, takes the answer it gave
    // last time.
    private suspend fun <T> fetch(load: suspend AutoXApi.() -> T): Pair<T, DataAge> =
        try {
            api.load() to DataAge(System.currentTimeMillis())
        } catch (e: ApiException) {
            if (!e.unreachable) throw e
            val saved = api.fromCache(load) ?: throw e
            saved.value to DataAge(saved.fetchedAt, refreshFailed = true)
        }

    fun retryStale() {
        if (current.isRetrying) return
        _state.update { it.copy(isRetrying = true) }
        viewModelScope.launch {
            try {
                when (current.route) {
                    RouteKind.LEADERBOARD -> current.openCourseId?.let { fetchLeaderboard(it) }
                    RouteKind.ACCELERATION -> fetchAcceleration()
                    RouteKind.BOARDS -> refreshLeaderboardEvents()
                    RouteKind.EVENTS -> loadEvents()
                    else -> if (current.eventsAge?.refreshFailed == true) loadEvents() else loadSessionData()
                }
            } finally {
                _state.update { it.copy(isRetrying = false) }
            }
        }
    }

    fun refreshEvents() {
        viewModelScope.launch { loadEvents() }
    }

    suspend fun loadEvents() {
        _state.update { it.copy(isLoading = true, errorMessage = null) }
        try {
            val (org, speedhive, gglc, leaderboard) = coroutineScope {
                val org = async { runCatching { fetch { org(AppState.DEFAULT_ORG_ID) }.first }.getOrNull() }
                val gglc = async { loadGGLCEvents() }
                val leaderboard = async { loadLeaderboardEvents() }
                val speedhive = fetch { events(AppState.DEFAULT_ORG_ID) }
                Quad(org.await(), speedhive, gglc.await(), leaderboard.await())
            }
            val leaderboardEvents = leaderboard?.first ?: current.events.filter { it.source == EventSource.LEADERBOARD }
            val events = (speedhive.first + gglc.first).sortedByDescending { it.startDate ?: "" } + leaderboardEvents
            _state.update {
                it.copy(
                    events = events,
                    orgName = org?.name,
                    eventsAge = AppState.combined(listOf(speedhive.second, gglc.second)),
                    boardsAge = leaderboard?.second ?: it.boardsAge,
                )
            }
            // Only an event the user opened is remembered; until then every
            // launch follows the newest one. A reload keeps what's on screen.
            val s = current
            val stillThere = s.events.firstOrNull { it.id == s.selectedEventId }?.id
            val eventId = stillThere ?: s.restorableEventId ?: s.defaultEventId
            if (eventId != null) {
                selectEvent(eventId, remember = false)
            } else {
                _state.update { it.copy(isLoading = false) }
            }
        } catch (e: Exception) {
            _state.update {
                it.copy(errorMessage = e.message, isLoading = false, eventsAge = it.eventsAge?.copy(refreshFailed = true))
            }
        }
    }

    private data class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)

    // GGLC failures only cost the extra events; Speedhive stays usable. A
    // year that doesn't load keeps the events already shown for it, so a
    // dropout never takes an event (or the one on screen) away.
    private suspend fun loadGGLCEvents(): Pair<List<SHEvent>, DataAge?> = coroutineScope {
        val year = today().year
        val thisYear = async { runCatching { fetch { gglcEvents(year) } }.getOrNull() }
        val lastYear = async { runCatching { fetch { gglcEvents(year - 1) } }.getOrNull() }
        val years = listOf(year to thisYear.await(), year - 1 to lastYear.await())
        val shown = current.events.filter { it.source == EventSource.GGLC }
        val events = years.flatMap { (listYear, loaded) ->
            loaded?.first?.mapNotNull { stub ->
                AppState.gglcEventId(stub.date)?.let { id ->
                    SHEvent(
                        id = id,
                        name = "GGLC Autocross",
                        startDate = stub.date,
                        location = SHLocation(name = "Golden Gate Lotus Club"),
                        source = EventSource.GGLC,
                    )
                }
            } ?: shown.filter { it.startDate?.startsWith("$listYear-") == true }
        }
        events to AppState.combined(years.map { it.second?.second })
    }

    // Like GGLC, leaderboard failures only cost the extra rows. Null means
    // nothing came back, so the boards already shown stay.
    private suspend fun loadLeaderboardEvents(): Pair<List<SHEvent>, DataAge>? {
        val courses = runCatching { fetch { leaderboardCourses() } }.getOrNull()
        if (courses == null) {
            _state.update { it.copy(boardsAge = it.boardsAge?.copy(refreshFailed = true)) }
            return null
        }
        _state.update { it.copy(leaderboardCourses = courses.first) }
        val hidden = current.settings.hiddenCourseIds
        return courses.first.filter { it.id !in hidden }.map(::leaderboardEvent) to courses.second
    }

    private fun leaderboardEvent(course: LBCourse) = SHEvent(
        id = AppState.leaderboardEventId(course.id),
        name = course.name,
        location = SHLocation(
            name = course.createdBy?.let { "by $it" },
            lengthLabel = course.distanceMiles?.let { String.format(Locale.US, "%.2f mi", it) },
        ),
        source = EventSource.LEADERBOARD,
    )

    suspend fun refreshLeaderboardEvents() {
        val (leaderboard, age) = loadLeaderboardEvents() ?: return
        _state.update { s ->
            s.copy(events = s.events.filter { it.source != EventSource.LEADERBOARD } + leaderboard, boardsAge = age)
        }
    }

    fun openEvent(eventId: Int) {
        val event = current.events.firstOrNull { it.id == eventId } ?: return
        if (event.source == EventSource.LEADERBOARD) {
            navChannel.trySend(NavCommand.OpenLeaderboard(AppState.leaderboardCourseId(eventId)))
            return
        }
        navChannel.trySend(NavCommand.ShowLive)
        if (eventId == current.selectedEventId && current.drivers.isNotEmpty()) return
        // Stale rows from the old session would make a failed load look like
        // the switch never happened, especially between same-named events.
        _state.update {
            it.copy(
                drivers = emptyList(),
                driversAge = null,
                compareSelection = emptyList(),
                sessions = emptyList(),
                selectedSessionId = null,
                isLoading = true,
            )
        }
        viewModelScope.launch { selectEvent(eventId) }
    }

    fun pickSession(sessionId: Int) {
        if (sessionId == current.selectedSessionId) return
        navChannel.trySend(NavCommand.ShowLive)
        _state.update { it.copy(drivers = emptyList(), driversAge = null, compareSelection = emptyList(), isLoading = true) }
        viewModelScope.launch { selectSession(sessionId) }
    }

    // Loads overlap when the user taps around faster than the network; after
    // every await, a load whose event or session is no longer the selected
    // one stops without touching state.
    suspend fun selectEvent(eventId: Int, remember: Boolean = true) {
        _state.update { it.copy(selectedEventId = eventId, isLoading = true, errorMessage = null) }
        if (remember) editSettings { it.copy(selectedEventId = eventId) }
        try {
            val fetched = if (eventId < 0) gglcSessions(eventId) else fetch { sessions(eventId) }.first
            if (current.selectedEventId != eventId) return
            _state.update { it.copy(sessions = fetched) }
            val saved = current.settings.sessionChoice[eventId.toString()]
            val sessionId = fetched.firstOrNull { it.id == saved }?.id ?: AppState.latestSession(fetched)?.id
            if (sessionId != null) {
                selectSession(sessionId)
            } else {
                _state.update { it.copy(drivers = emptyList(), isLoading = false) }
            }
        } catch (e: Exception) {
            if (current.selectedEventId != eventId) return
            _state.update { it.copy(errorMessage = e.message, isLoading = false) }
        }
    }

    private fun gglcSessions(eventId: Int) = listOf(SHSession(id = eventId, name = "Results"))

    suspend fun selectSession(sessionId: Int) {
        _state.update { it.copy(selectedSessionId = sessionId) }
        current.selectedEventId?.let { eventId ->
            editSettings { it.copy(sessionChoice = it.sessionChoice + (eventId.toString() to sessionId)) }
        }
        loadSessionData()
    }

    fun reload() {
        viewModelScope.launch { loadSessionData() }
    }

    // Pulling down on a results page. With nothing showing, the event may
    // have gained its first session since it was opened, so it is reopened.
    suspend fun reloadResults() {
        val eventId = current.selectedEventId
        when {
            eventId == null -> loadEvents()
            current.drivers.isEmpty() -> selectEvent(eventId, remember = false)
            else -> loadSessionData()
        }
    }

    suspend fun reloadLeaderboard() {
        current.openCourseId?.let { fetchLeaderboard(it) }
    }

    suspend fun reloadAcceleration() = fetchAcceleration()

    suspend fun loadSessionData() {
        val sessionId = current.selectedSessionId ?: return
        _state.update { it.copy(isLoading = true, errorMessage = null) }
        lastSessionLoad = System.currentTimeMillis()
        try {
            val (loaded, age) = fetch { drivers(sessionId) }
            if (current.selectedSessionId != sessionId) return
            _state.update { it.copy(drivers = loaded, driversAge = age) }
        } catch (e: Exception) {
            if (current.selectedSessionId != sessionId) return
            _state.update { it.copy(errorMessage = e.message, driversAge = it.driversAge?.copy(refreshFailed = true)) }
        }
        _state.update { it.copy(isLoading = false) }
    }

    // The automatic reload: no spinner, and a failure leaves the last results
    // up, marked as old, rather than replacing a live board with an error.
    // Driver and compare pages are addressed by car number, so they follow
    // their drivers to whatever positions the new times give them.
    suspend fun refreshSessionData() {
        lastSessionLoad = System.currentTimeMillis()
        if (current.isLoading) return
        val eventId = current.selectedEventId
        // Speedhive adds sessions through the day; GGLC has only the one.
        if (eventId != null && eventId > 0) {
            val fetched = runCatching { api.sessions(eventId) }.getOrNull()
            if (fetched != null && current.selectedEventId == eventId && fetched != current.sessions) {
                _state.update {
                    it.copy(sessions = fetched, selectedSessionId = it.selectedSessionId ?: AppState.latestSession(fetched)?.id)
                }
            }
        }
        val sessionId = current.selectedSessionId ?: return
        val loaded = runCatching { api.drivers(sessionId) }.getOrNull()
        if (current.selectedSessionId != sessionId) return
        if (loaded == null) {
            _state.update { it.copy(driversAge = it.driversAge?.copy(refreshFailed = true)) }
            return
        }
        _state.update {
            it.copy(drivers = loaded, driversAge = DataAge(System.currentTimeMillis()), errorMessage = null)
        }
    }

    fun openLeaderboard(courseId: Int) {
        _state.update { it.copy(openCourseId = courseId, leaderboardDetail = null, leaderboardAge = null) }
        viewModelScope.launch { fetchLeaderboard(courseId) }
    }

    private suspend fun fetchLeaderboard(courseId: Int) {
        _state.update { it.copy(leaderboardError = null) }
        try {
            val (detail, age) = fetch { leaderboardCourse(courseId) }
            if (current.openCourseId != courseId) return
            _state.update { it.copy(leaderboardDetail = detail, leaderboardAge = age) }
        } catch (e: Exception) {
            if (current.openCourseId != courseId) return
            _state.update { it.copy(leaderboardError = e.message, leaderboardAge = it.leaderboardAge?.copy(refreshFailed = true)) }
        }
    }

    // The last list stays up while it reloads; the board changes rarely.
    fun loadAcceleration() {
        viewModelScope.launch { fetchAcceleration() }
    }

    private suspend fun fetchAcceleration() {
        _state.update { it.copy(accelerationError = null) }
        try {
            val (entries, age) = fetch { acceleration() }
            _state.update { it.copy(accelerationEntries = entries, accelerationAge = age) }
        } catch (e: Exception) {
            _state.update { it.copy(accelerationError = e.message, accelerationAge = it.accelerationAge?.copy(refreshFailed = true)) }
        }
    }

    suspend fun joinCourse(code: String) {
        val course = api.joinCourse(code)
        editSettings { it.copy(hiddenCourseIds = it.hiddenCourseIds - course.id) }
        refreshLeaderboardEvents()
        navChannel.trySend(NavCommand.OpenLeaderboard(course.id))
    }

    suspend fun leaveCourse(id: Int) {
        api.leaveCourse(id)
        refreshLeaderboardEvents()
        navChannel.trySend(NavCommand.LeaveLeaderboard(id))
    }

    fun hideCourse(id: Int) {
        editSettings { it.copy(hiddenCourseIds = it.hiddenCourseIds + id) }
        _state.update { s -> s.copy(events = s.events.filter { it.id != AppState.leaderboardEventId(id) }) }
        navChannel.trySend(NavCommand.LeaveLeaderboard(id))
    }

    fun unhideAllCourses() {
        editSettings { it.copy(hiddenCourseIds = emptySet()) }
        viewModelScope.launch { refreshLeaderboardEvents() }
    }

    suspend fun report(target: LBReportTarget, reason: String) = api.report(target, reason)

    // The server stops sending anything the blocked poster owns, so the open
    // board is reloaded, or left if it was theirs.
    suspend fun blockPoster(target: LBReportTarget, courseId: Int) {
        val block = api.block(target)
        _state.update { s -> s.copy(blocks = listOf(block) + s.blocks.filter { it.id != block.id }) }
        refreshLeaderboardEvents()
        if (current.leaderboardCourses.any { it.id == courseId }) {
            navChannel.trySend(NavCommand.BackToLeaderboard(courseId))
            openLeaderboard(courseId)
        } else {
            navChannel.trySend(NavCommand.LeaveLeaderboard(courseId))
        }
    }

    suspend fun blockAccelerationPoster(entryId: Int) {
        val block = api.block(LBReportTarget(LBReportType.ACCELERATION, entryId))
        _state.update { s ->
            s.copy(
                blocks = listOf(block) + s.blocks.filter { it.id != block.id },
                accelerationEntries = s.accelerationEntries?.filter { it.id != entryId },
            )
        }
        navChannel.trySend(NavCommand.BackToAcceleration)
        loadAcceleration()
        refreshLeaderboardEvents()
    }

    suspend fun unblock(id: Int) {
        api.unblock(id)
        _state.update { s -> s.copy(blocks = s.blocks.filter { it.id != id }) }
        refreshLeaderboardEvents()
    }

    fun loadBlocks() {
        viewModelScope.launch {
            runCatching { api.blocks() }.getOrNull()?.let { blocks -> _state.update { it.copy(blocks = blocks) } }
        }
    }
}
