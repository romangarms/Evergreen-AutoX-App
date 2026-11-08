package com.romangarms.autoxlive.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import java.util.Locale

@Serializable
data class SHOrg(val id: Int? = null, val name: String? = null)

enum class EventSource(val label: String) {
    SPEEDHIVE("Speedhive"),
    GGLC("GGLC"),
    LEADERBOARD("Leaderboards"),
}

// The server sends no source field; decoded events are always Speedhive, and
// the other sources are constructed locally.
@Serializable
data class SHEvent(
    val id: Int,
    val name: String,
    val startDate: String? = null,
    val location: SHLocation? = null,
    @Transient val source: EventSource = EventSource.SPEEDHIVE,
)

@Serializable
data class SHLocation(val name: String? = null, val lengthLabel: String? = null)

@Serializable
data class SHSession(
    val id: Int,
    val name: String? = null,
    val type: String? = null,
    val startTime: String? = null,
    val resultStatus: String? = null,
)

@Serializable
data class SHResultRow(
    val position: Int? = null,
    val name: String? = null,
    val startNumber: String? = null,
    val resultClass: String? = null,
    val bestTime: String? = null,
    val numberOfLaps: Int? = null,
    val positionInClass: Int? = null,
    val bestSpeed: Double? = null,
    val status: String? = null,
)

@Serializable
data class SHLapsRow(val position: Int? = null, val laps: List<SHLap>? = null)

@Serializable
data class SHLap(
    val lap: Int? = null,
    val lapTime: String? = null,
    val timeOfDay: Double? = null,
    val speed: Double? = null,
)

@Serializable
data class GGLCEventStub(val date: String, val url: String)

@Serializable
data class GGLCEvent(
    val date: String,
    val url: String,
    val title: String,
    val updated: String,
    val classes: List<GGLCClass>,
)

@Serializable
data class GGLCClass(val name: String, val runCount: Int, val drivers: List<GGLCDriver>)

@Serializable
data class GGLCDriver(
    val name: String,
    val car: String,
    val make: String,
    val model: String,
    val carClass: String,
    val indexed: Double? = null,
    val runs: List<GGLCRun>,
) {
    // Some entrants type the make into the model column too ("Nissan Nissan").
    val carName: String
        get() = (if (model.equals(make, ignoreCase = true)) listOf(make) else listOf(make, model))
            .filter { it.isNotEmpty() }
            .joinToString(" ")
}

@Serializable
data class GGLCRun(
    val run: Int,
    val raw: String,
    val time: Double? = null,
    val cones: Int,
    val dnf: Boolean,
    val total: Double? = null,
    val best: Boolean,
) {
    // The live page shows 0.000 for a car still on course. The server drops
    // those now, but saved and older answers can carry one, and it is no time.
    val score: Double? get() = total?.takeIf { it > 0 }
}

@Serializable
data class LBCourse(
    val id: Int,
    val name: String,
    @SerialName("distance_miles") val distanceMiles: Double? = null,
    @SerialName("legacy_distance_miles") val legacyDistanceMiles: Double? = null,
    val description: String? = null,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("is_owner") val isOwner: Boolean = false,
    @SerialName("has_owner") val hasOwner: Boolean = false,
    val unlisted: Boolean = false,
    @SerialName("is_member") val isMember: Boolean = false,
    @SerialName("join_code") val joinCode: String? = null,
)

@Serializable
data class LBJoinInput(val code: String)

enum class LBReportType(val wire: String) { COURSE("course"), RUN("run"), ACCELERATION("acceleration") }

data class LBReportTarget(val type: LBReportType, val targetId: Int)

@Serializable
data class LBReportInput(
    @SerialName("target_type") val targetType: String,
    @SerialName("target_id") val targetId: Int,
    val reason: String,
) {
    constructor(target: LBReportTarget, reason: String) : this(target.type.wire, target.targetId, reason)
}

@Serializable
data class LBBlockInput(
    @SerialName("target_type") val targetType: String,
    @SerialName("target_id") val targetId: Int,
) {
    constructor(target: LBReportTarget) : this(target.type.wire, target.targetId)
}

@Serializable
data class LBBlock(val id: Int, val label: String? = null)

@Serializable
data class Created(val id: Int)

@Serializable
data class Deleted(val deleted: Int)

@Serializable
data class AccelEntry(
    val id: Int,
    val year: Int? = null,
    val vehicle: String,
    val driver: String? = null,
    val hp: Int? = null,
    @SerialName("weight_lb") val weightLb: Int? = null,
    @SerialName("zero_to_30_seconds") val zeroTo30: Double? = null,
    @SerialName("zero_to_60_seconds") val zeroTo60: Double? = null,
    @SerialName("quarter_mile_seconds") val quarterMileSeconds: Double? = null,
    @SerialName("quarter_mile_mph") val quarterMileMph: Double? = null,
    @SerialName("eighth_mile_seconds") val eighthMileSeconds: Double? = null,
    @SerialName("eighth_mile_mph") val eighthMileMph: Double? = null,
    val notes: String? = null,
    @SerialName("is_owner") val isOwner: Boolean? = null,
    @SerialName("has_owner") val hasOwner: Boolean? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("other_runs") val otherRuns: List<AccelEntry>? = null,
) {
    val canBlockPoster: Boolean get() = hasOwner == true && isOwner != true

    val postedOn: String? get() = createdAt?.take(10)

    val title: String get() = listOfNotNull(year?.toString(), vehicle).joinToString(" ")
}

@Serializable
data class LBCourseDetail(val course: LBCourse, val runs: List<LBRun>)

@Serializable
data class LBRun(
    val id: Int,
    val driver: String,
    val vehicle: String? = null,
    val hp: Int? = null,
    val time: String,
    @SerialName("adjusted_seconds") val adjustedSeconds: Double,
    @SerialName("adjusted_time") val adjustedTime: String,
    @SerialName("avg_speed_mph") val avgSpeedMph: Double? = null,
    @SerialName("top_speed_mph") val topSpeedMph: Double? = null,
    @SerialName("run_date") val runDate: String? = null,
    val conditions: String? = null,
    val notes: String? = null,
    val legacy: Boolean,
    @SerialName("is_owner") val isOwner: Boolean = false,
    @SerialName("has_owner") val hasOwner: Boolean = false,
) {
    val canBlockPoster: Boolean get() = hasOwner && !isOwner
}

@Serializable
data class AndroidRelease(
    @SerialName("version_name") val versionName: String,
    @SerialName("version_code") val versionCode: Int,
    val sha256: String,
    val size: Long? = null,
    @SerialName("download_url") val downloadUrl: String = "/android",
)

// A driver's runs in one car. The same driver in another car is a separate
// entry with its own rank, so a record in each car stays visible.
class LBEntry(rank: Int, val best: LBRun, val runs: List<LBRun>) {
    val driver = Driver.leaderboard(rank, best.driver, runs)
    val id: Int get() = driver.position

    companion object {
        fun groupKey(run: LBRun): String =
            run.driver + "\u0000" + (run.vehicle ?: "").trim().lowercase()

        fun entries(runs: List<LBRun>): List<LBEntry> =
            runs.groupBy(::groupKey).values
                .map { group -> group.minBy { it.adjustedSeconds } to group }
                .sortedWith(
                    compareBy<Pair<LBRun, List<LBRun>>>(
                        { it.first.adjustedSeconds },
                        { it.first.driver },
                        { it.first.vehicle ?: "" },
                    ),
                )
                .mapIndexed { index, (best, group) -> LBEntry(index + 1, best, group) }
    }
}

object LapTime {
    fun seconds(string: String?): Double? {
        if (string.isNullOrEmpty()) return null
        var total = 0.0
        for (part in string.split(":")) {
            val value = part.toDoubleOrNull() ?: return null
            total = total * 60 + value
        }
        return total
    }

    fun format(seconds: Double): String {
        if (seconds < 60) return String.format(Locale.US, "%.3f", seconds)
        val minutes = seconds.toInt() / 60
        return String.format(Locale.US, "%d:%06.3f", minutes, seconds - minutes * 60)
    }

    fun gap(delta: Double): String = String.format(Locale.US, "%+.2f", delta)
}

// A DNF has no time; `seconds` is 0 and it stays out of every statistic.
data class Run(
    val number: Int,
    val lapNumber: Int,
    val seconds: Double,
    val speed: Double? = null,
    val timeOfDayMillis: Double? = null,
    val cones: Int = 0,
    val dnf: Boolean = false,
) {
    val id: Int get() = lapNumber
    val timeString: String get() = if (dnf) "DNF" else LapTime.format(seconds)
}

data class Driver(
    val position: Int,
    val name: String,
    val startNumber: String,
    val carClass: String?,
    val positionInClass: Int?,
    val runs: List<Run>,
    // GGLC scores only the first 5 runs; we rank by best of all runs instead.
    val officialRunNumber: Int?,
    private val bestTimeString: String?,
    val vehicle: String? = null,
) {
    val id: Int get() = position

    val timedRuns: List<Run> get() = runs.filter { !it.dnf }

    val best: Double? get() = timedRuns.minOfOrNull { it.seconds } ?: LapTime.seconds(bestTimeString)

    val officialBest: Double? get() = timedRuns.firstOrNull { it.number == officialRunNumber }?.seconds

    val bestString: String get() = best?.let(LapTime::format) ?: "—"

    val average: Double?
        get() = timedRuns.takeIf { it.isNotEmpty() }?.let { runs -> runs.sumOf { it.seconds } / runs.size }

    val spread: Double?
        get() {
            val times = timedRuns.map { it.seconds }
            if (times.size < 2) return null
            return times.max() - times.min()
        }

    companion object {
        // Transponders keep lapping between runs, so a "lap" can be a 3-minute
        // to 90-minute wait in grid. A lap counts as a run only if it's under
        // this ceiling AND under 2x the driver's fastest lap (short queue laps
        // would otherwise slip through and wreck averages). Mirrored in
        // server/notify.py and the iOS Driver.
        const val MAX_RUN_SECONDS = 300.0

        // GGLC "total" already includes cone penalties (1s/cone).
        fun gglc(position: Int, gglc: GGLCDriver, carClass: String?, positionInClass: Int?): Driver {
            val carName = gglc.carName
            val name = when {
                gglc.name.isNotEmpty() -> gglc.name
                carName.isNotEmpty() -> carName
                gglc.car.isNotEmpty() -> "Car ${gglc.car}"
                else -> "(unknown)"
            }
            return Driver(
                position = position,
                name = name,
                startNumber = gglc.car.ifEmpty { "P$position" },
                carClass = carClass,
                positionInClass = positionInClass,
                runs = gglc.runs.mapNotNull { run ->
                    when {
                        run.dnf -> Run(number = run.run, lapNumber = run.run, seconds = 0.0, dnf = true)
                        else -> run.score?.let { Run(number = run.run, lapNumber = run.run, seconds = it, cones = run.cones) }
                    }
                },
                officialRunNumber = gglc.runs.firstOrNull { it.best && it.score != null }?.run,
                bestTimeString = null,
                vehicle = carName.takeIf {
                    it.isNotEmpty() && it != name && !it.equals(carClass ?: "", ignoreCase = true)
                },
            )
        }

        // Leaderboard drivers have no car number, so the name doubles as the
        // startNumber; pins and nicknames are keyed by car number and won't match.
        fun leaderboard(rank: Int, name: String, runs: List<LBRun>): Driver {
            val vehicles = runs.mapNotNull { it.vehicle }.distinct()
            return Driver(
                position = rank,
                name = name,
                startNumber = name,
                carClass = vehicles.takeIf { it.isNotEmpty() }?.joinToString(", "),
                positionInClass = null,
                runs = runs.sortedBy { it.runDate ?: "" }.mapIndexed { index, run ->
                    Run(number = index + 1, lapNumber = run.id, seconds = run.adjustedSeconds, speed = run.avgSpeedMph)
                },
                officialRunNumber = null,
                bestTimeString = null,
            )
        }

        fun speedhive(result: SHResultRow, laps: List<SHLap>): Driver {
            val fastest = laps
                .mapNotNull { LapTime.seconds(it.lapTime) }
                .filter { it > 0 && it < MAX_RUN_SECONDS }
                .minOrNull()
            val cutoff = fastest?.let { minOf(MAX_RUN_SECONDS, it * 2) } ?: MAX_RUN_SECONDS
            var runNumber = 0
            val runs = laps.mapNotNull { lap ->
                val seconds = LapTime.seconds(lap.lapTime)
                if (seconds == null || seconds <= 0 || seconds >= cutoff) return@mapNotNull null
                runNumber += 1
                Run(
                    number = runNumber,
                    lapNumber = lap.lap ?: runNumber,
                    seconds = seconds,
                    speed = lap.speed,
                    timeOfDayMillis = lap.timeOfDay,
                )
            }
            return Driver(
                position = result.position ?: 0,
                name = result.name ?: "(unknown)",
                startNumber = result.startNumber ?: "P${result.position ?: 0}",
                carClass = result.resultClass,
                positionInClass = result.positionInClass,
                runs = runs,
                officialRunNumber = null,
                bestTimeString = result.bestTime,
            )
        }
    }
}

object SessionResults {
    fun speedhiveDrivers(results: List<SHResultRow>, laps: List<SHLapsRow>): List<Driver> {
        val lapsByPosition = mutableMapOf<Int, List<SHLap>>()
        for (row in laps) {
            val position = row.position ?: continue
            lapsByPosition.putIfAbsent(position, row.laps ?: emptyList())
        }
        return results
            .map { Driver.speedhive(it, lapsByPosition[it.position ?: -1] ?: emptyList()) }
            .sortedBy { it.position }
    }

    // GGLC sessions carry the event's -yyyymmdd ID (see AppViewModel.gglcEventId).
    fun gglcDate(eventId: Int): String {
        val digits = (-eventId).toString()
        return "${digits.take(4)}-${digits.drop(4).take(2)}-${digits.takeLast(2)}"
    }

    // Mirrored in server/notify.py (_gglc_cars) and the iOS gglcDrivers.
    fun gglcDrivers(event: GGLCEvent): List<Driver> {
        data class Ranked(val driver: GGLCDriver, val carClass: String, val best: Double?)

        val ranked = event.classes
            .flatMap { klass ->
                klass.drivers.map { driver ->
                    Ranked(
                        driver = driver,
                        carClass = driver.carClass.ifEmpty { klass.name },
                        best = driver.runs.mapNotNull { it.score }.minOrNull(),
                    )
                }
            }
            .sortedWith { a, b ->
                when {
                    a.best != null && b.best != null -> a.best.compareTo(b.best)
                    a.best != null -> -1
                    b.best != null -> 1
                    else -> a.driver.name.compareTo(b.driver.name)
                }
            }
        val classCounts = mutableMapOf<String, Int>()
        return ranked.mapIndexed { index, entry ->
            val count = (classCounts[entry.carClass] ?: 0) + 1
            classCounts[entry.carClass] = count
            Driver.gglc(index + 1, entry.driver, entry.carClass, count)
        }
    }
}
