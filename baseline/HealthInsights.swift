//
//  HealthInsights.swift
//  Baseline
//
//  Extra detail derived from Health data the app already reads: sleep stages and
//  timing, overnight vitals, HRV trends, the day's charge and heart-rate zones, and
//  activity load. Display only; none of this changes the scores.
//

import Foundation

// MARK: - Shared types

/// A value on a date, for charts and stats.
nonisolated struct DatedValue: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Sleep stages as shown in the app (in-bed time isn't shown).
nonisolated enum SleepStageKind: String, CaseIterable, Sendable {
    // Top-to-bottom order in the hypnogram
    case awake = "Awake"
    case rem = "REM"
    case core = "Core"
    case deep = "Deep"
}

private typealias Span = (start: Date, end: Date)

// MARK: - Sleep

nonisolated struct HypnogramSegment: Identifiable, Sendable {
    let id = UUID()
    let start: Date
    let end: Date
    let stage: SleepStageKind
}

nonisolated struct NightSummary: Identifiable, Sendable {
    let night: Date
    let asleep: TimeInterval
    let deep: TimeInterval
    let core: TimeInterval
    let rem: TimeInterval
    var id: Date { night }
}

nonisolated struct SleepInsights: Sendable {
    // Last night's main sleep
    var bedtime: Date?
    var wakeTime: Date?
    var asleep: TimeInterval = 0
    var deep: TimeInterval = 0
    var core: TimeInterval = 0
    var rem: TimeInterval = 0
    var awake: TimeInterval = 0
    var awakenings = 0
    /// Time asleep divided by time from falling asleep to waking
    var efficiency: Double?
    var hypnogram: [HypnogramSegment] = []

    // Overnight vitals
    var averageSleepingHR: Double?
    var lowestSleepingHR: Double?
    var respiratoryRate: Double?
    var bloodOxygenAverage: Double?
    var bloodOxygenLowest: Double?
    /// Last night's sleeping wrist temperature (absolute °C, as Apple Health records it)
    var wristTemperature: Double?

    // Last 7 nights, oldest first
    var nights: [NightSummary] = []
    /// Typical bedtime and wake time, as offsets from midnight of the morning you woke up
    /// (bedtimes before midnight are negative)
    var usualBedtimeOffset: TimeInterval?
    var usualWakeOffset: TimeInterval?
    /// Standard deviation of bedtime and wake time across the 7 nights
    var bedtimeVariability: TimeInterval?
    var wakeVariability: TimeInterval?
    /// Total shortfall vs. your usual sleep across the 7 nights
    var sleepDebt: TimeInterval?
}

/// Builds sleep insights for the night ending on `night` (a start of day).
nonisolated func makeSleepInsights(
    sleep: [SleepSample],
    heartRate: [HeartRateSample],
    respiratory: [RespiratoryRateSample],
    oxygen: [BloodOxygenSample],
    temperature: [WristTemperatureSample],
    usualSleepHours: Double?,
    night: Date,
    calendar: Calendar = .current
) -> SleepInsights {
    var insights = SleepInsights()

    // Last 7 nights
    let nightly = sleep.nightlySleepHours(calendar: calendar)
    let nights = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: night) }
    insights.nights = nights.compactMap { day in
        guard let hours = nightly[day] else { return nil }
        let stages = stageDurations(sleep, night: day, within: nil, calendar: calendar)
        return NightSummary(
            night: day,
            asleep: hours * 3600,
            deep: stages[.deep] ?? 0,
            core: stages[.core] ?? 0,
            rem: stages[.rem] ?? 0
        )
    }

    // Timing consistency
    let blocks = nights.compactMap { day in mainSleepBlock(sleep, night: day, calendar: calendar).map { (day, $0) } }
    let bedOffsets = blocks.map { $0.1.start.timeIntervalSince($0.0) }
    let wakeOffsets = blocks.map { $0.1.end.timeIntervalSince($0.0) }
    if bedOffsets.count >= 3 {
        insights.usualBedtimeOffset = insightMean(bedOffsets)
        insights.usualWakeOffset = insightMean(wakeOffsets)
        insights.bedtimeVariability = insightStandardDeviation(bedOffsets)
        insights.wakeVariability = insightStandardDeviation(wakeOffsets)
    }

    if let usualSleepHours, !insights.nights.isEmpty {
        insights.sleepDebt = insights.nights.reduce(0) { $0 + max(0, usualSleepHours * 3600 - $1.asleep) }
    }

    // Last night
    guard let block = mainSleepBlock(sleep, night: night, calendar: calendar) else { return insights }
    insights.bedtime = block.start
    insights.wakeTime = block.end

    let stages = stageDurations(sleep, night: night, within: block, calendar: calendar)
    insights.deep = stages[.deep] ?? 0
    insights.core = stages[.core] ?? 0
    insights.rem = stages[.rem] ?? 0
    insights.asleep = insights.deep + insights.core + insights.rem

    let awakeSpans = union(sleep.compactMap { sample -> Span? in
        guard case .awake = sample.value else { return nil }
        return clip((sample.startDate, sample.endDate), to: block)
    })
    insights.awake = totalDuration(awakeSpans)
    insights.awakenings = awakeSpans.filter { $0.end.timeIntervalSince($0.start) >= 60 }.count

    let blockDuration = block.end.timeIntervalSince(block.start)
    if blockDuration > 0 {
        insights.efficiency = min(1, insights.asleep / blockDuration)
    }

    insights.hypnogram = sleep
        .compactMap { sample -> HypnogramSegment? in
            guard let kind = stageKind(sample.value),
                  let span = clip((sample.startDate, sample.endDate), to: block) else { return nil }
            return HypnogramSegment(start: span.start, end: span.end, stage: kind)
        }
        .sorted { $0.start < $1.start }

    // Overnight vitals during the main sleep
    func isDuringSleep(_ date: Date) -> Bool { date >= block.start && date <= block.end }

    let sleepingHR = heartRate.filter { isDuringSleep($0.date) }.map(\.value)
    insights.averageSleepingHR = insightMean(sleepingHR)
    insights.lowestSleepingHR = sleepingHR.min()

    insights.respiratoryRate = insightMean(respiratory.filter { isDuringSleep($0.date) }.map(\.value))

    let spO2 = oxygen.filter { isDuringSleep($0.date) }.map(\.value)
    insights.bloodOxygenAverage = insightMean(spO2)
    insights.bloodOxygenLowest = spO2.min()

    // Apple records one wrist temperature reading per night, around the sleep
    insights.wristTemperature = temperature.first {
        $0.date >= block.start.addingTimeInterval(-3 * 3600) && $0.date <= block.end.addingTimeInterval(3 * 3600)
    }?.value

    return insights
}

/// The longest stretch of sleep in a night (brief awakenings under an hour are bridged).
nonisolated func mainSleepBlock(_ sleep: [SleepSample], night: Date, calendar: Calendar = .current) -> (start: Date, end: Date)? {
    sleep.asleepIntervalsByNight(joiningGap: 3600, calendar: calendar)[night]?
        .max { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
}

/// Time in each stage for a night, optionally limited to `block`. Overlapping records
/// from several sources are merged, and asleep stages are scaled to the merged total
/// so they never add up to more than the time actually asleep.
private nonisolated func stageDurations(
    _ sleep: [SleepSample],
    night: Date,
    within block: Span?,
    calendar: Calendar
) -> [SleepStageKind: TimeInterval] {
    var spansByStage: [SleepStageKind: [Span]] = [:]
    for sample in sleep {
        guard let kind = stageKind(sample.value),
              sleepNightKey(for: sample.startDate, calendar: calendar) == night else { continue }
        var span: Span = (sample.startDate, sample.endDate)
        if let block {
            guard let clipped = clip(span, to: block) else { continue }
            span = clipped
        }
        spansByStage[kind, default: []].append(span)
    }

    var durations = spansByStage.mapValues { totalDuration(union($0)) }

    let asleepSpans = [SleepStageKind.deep, .core, .rem].flatMap { spansByStage[$0] ?? [] }
    let asleepTotal = totalDuration(union(asleepSpans))
    let stageSum = [SleepStageKind.deep, .core, .rem].reduce(0) { $0 + (durations[$1] ?? 0) }
    if stageSum > 0 {
        let scale = asleepTotal / stageSum
        for stage in [SleepStageKind.deep, .core, .rem] {
            durations[stage] = (durations[stage] ?? 0) * scale
        }
    }
    return durations
}

private nonisolated func stageKind(_ stage: SleepSample.SleepStage) -> SleepStageKind? {
    switch stage {
    case .asleepDeep: .deep
    case .asleepCore: .core
    case .asleepREM: .rem
    case .awake: .awake
    case .inBed: nil
    }
}

// MARK: - HRV

nonisolated struct HRVInsights: Sendable {
    var lastNight: Double?
    var lastNightLow: Double?
    var lastNightHigh: Double?
    var readingsLastNight = 0
    /// One value per night for the last 30 nights, oldest first
    var nightly: [DatedValue] = []
    /// 7-night rolling average (geometric mean) for each night with enough data
    var rolling: [DatedValue] = []
    /// Your usual nightly HRV and the "normal" band around it (usual ± the smallest
    /// worthwhile change)
    var usual: Double?
    var normalLow: Double?
    var normalHigh: Double?
    /// Night-to-night variation over the last 7 nights (coefficient of variation, %)
    var variation: Double?
    /// Average of today's readings taken while awake
    var daytimeAverage: Double?
}

nonisolated func makeHRVInsights(
    hrv: [HRVSample],
    sleep: [SleepSample],
    night: Date,
    now: Date = .now,
    calendar: Calendar = .current
) -> HRVInsights {
    var insights = HRVInsights()
    let overnight = sleep.overnightHRVByNight(hrv, calendar: calendar)
    insights.lastNight = overnight[night]

    guard let start = calendar.date(byAdding: .day, value: -29, to: night) else { return insights }
    insights.nightly = overnight
        .filter { $0.key >= start && $0.key <= night && $0.value > 0 }
        .sorted { $0.key < $1.key }
        .map { DatedValue(date: $0.key, value: $0.value) }

    // HRV is right-skewed, so averages and spread are taken on its log
    insights.rolling = insights.nightly.compactMap { point in
        guard let windowStart = calendar.date(byAdding: .day, value: -6, to: point.date) else { return nil }
        let window = insights.nightly.filter { $0.date >= windowStart && $0.date <= point.date }
        guard window.count >= 3, let logMean = insightMean(window.map { log($0.value) }) else { return nil }
        return DatedValue(date: point.date, value: exp(logMean))
    }

    let logs = insights.nightly.map { log($0.value) }
    if logs.count >= 7, let mean = insightMean(logs), let sd = insightStandardDeviation(logs) {
        insights.usual = exp(mean)
        insights.normalLow = exp(mean - ScoringWeights.trivialZ * sd)
        insights.normalHigh = exp(mean + ScoringWeights.trivialZ * sd)
    }

    let lastWeek = insights.nightly.suffix(7).map(\.value)
    if lastWeek.count >= 4, let mean = insightMean(lastWeek), mean > 0, let sd = insightStandardDeviation(lastWeek) {
        insights.variation = sd / mean * 100
    }

    // Spread of last night's individual readings
    let asleep = sleep.asleepIntervalsByNight(joiningGap: 30 * 60, calendar: calendar)
    if let blocks = asleep[night] {
        let readings = hrv.filter { sample in blocks.contains { $0.start <= sample.date && sample.date <= $0.end } }.map(\.value)
        insights.readingsLastNight = readings.count
        insights.lastNightLow = readings.min()
        insights.lastNightHigh = readings.max()
    }

    // Today's daytime readings
    let allAsleep = asleep.values.flatMap { $0 }
    let startOfToday = calendar.startOfDay(for: now)
    let daytime = hrv.filter { sample in
        sample.date >= startOfToday && !allAsleep.contains { $0.start <= sample.date && sample.date <= $0.end }
    }
    insights.daytimeAverage = insightMean(daytime.map(\.value))

    return insights
}

// MARK: - Body Charge

nonisolated enum HeartZone: String, CaseIterable, Sendable {
    case rest = "Rest"
    case light = "Light"
    case moderate = "Moderate"
    case vigorous = "Vigorous"

    /// Upper bound in bpm above your calm daytime heart rate
    var upperBound: Double {
        switch self {
        case .rest: 5
        case .light: 20
        case .moderate: 45
        case .vigorous: .infinity
        }
    }
}

/// Health data for today's charge insights, loaded once; the charge snapshots come
/// from the database and are combined at display time.
nonisolated struct ChargeInputs: Sendable {
    var heartRate: [HeartRateSample] = []
    var asleep: [DateInterval] = []
    var activeEnergy: Double?
    var exerciseMinutes: Double?
    /// From `SleepInsights.usualBedtimeOffset`
    var usualBedtimeOffset: TimeInterval?
}

nonisolated struct ChargeInsights: Sendable {
    var peak: DatedValue?
    var low: DatedValue?
    var drained: Double = 0
    var recharged: Double = 0
    var zoneMinutes: [HeartZone: Double] = [:]
    var activeEnergy: Double?
    var exerciseMinutes: Double?
    /// Expected level at your usual bedtime if the last 3 hours' trend continues
    var projection: DatedValue?
}

nonisolated func makeChargeInsights(
    snapshots: [DatedValue],
    inputs: ChargeInputs,
    now: Date = .now,
    calendar: Calendar = .current
) -> ChargeInsights {
    var insights = ChargeInsights()
    insights.activeEnergy = inputs.activeEnergy
    insights.exerciseMinutes = inputs.exerciseMinutes

    insights.peak = snapshots.max { $0.value < $1.value }
    insights.low = snapshots.min { $0.value < $1.value }
    for (earlier, later) in zip(snapshots, snapshots.dropFirst()) {
        let change = later.value - earlier.value
        if change < 0 { insights.drained -= change } else { insights.recharged += change }
    }

    // Time in heart-rate zones while awake today, relative to today's calm heart rate
    let startOfToday = calendar.startOfDay(for: now)
    let awake = inputs.heartRate
        .filter { sample in
            sample.date >= startOfToday && !inputs.asleep.contains { $0.contains(sample.date) }
        }
        .sorted { $0.date < $1.date }
    if awake.count >= 30 {
        let sorted = awake.map(\.value).sorted()
        let calm = sorted[Int(Double(sorted.count - 1) * ScoringWeights.calmHRPercentile)]
        for (index, sample) in awake.enumerated() {
            let next = index + 1 < awake.count ? awake[index + 1].date : now
            // Each reading stands for the time until the next one, up to 10 minutes
            let minutes = min(next.timeIntervalSince(sample.date), 600) / 60
            let above = sample.value - calm
            let zone = HeartZone.allCases.first { above <= $0.upperBound } ?? .vigorous
            insights.zoneMinutes[zone, default: 0] += minutes
        }
    }

    // Projection to tonight's usual bedtime at the average pace since waking (a single
    // busy hour shouldn't predict the whole evening)
    if let offset = inputs.usualBedtimeOffset,
       let first = snapshots.first,
       let last = snapshots.last,
       let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) {
        let bedtime = tomorrow.addingTimeInterval(offset)
        let hoursSoFar = last.date.timeIntervalSince(first.date) / 3600
        if bedtime > now, hoursSoFar >= 2 {
            let ratePerHour = (last.value - first.value) / hoursSoFar
            let hoursLeft = bedtime.timeIntervalSince(last.date) / 3600
            let projected = min(100, max(0, last.value + ratePerHour * hoursLeft))
            insights.projection = DatedValue(date: bedtime, value: projected)
        }
    }

    return insights
}

/// Value at a moment, interpolated between points (sorted by date).
nonisolated func interpolatedValue(_ points: [DatedValue], at date: Date) -> Double? {
    guard let first = points.first, let last = points.last,
          date >= first.date, date <= last.date else { return nil }
    guard let after = points.first(where: { $0.date >= date }) else { return nil }
    guard let before = points.last(where: { $0.date <= date }) else { return after.value }
    let span = after.date.timeIntervalSince(before.date)
    guard span > 0 else { return before.value }
    return before.value + (after.value - before.value) * date.timeIntervalSince(before.date) / span
}

// MARK: - Recovery extras

nonisolated struct RecoveryExtras: Sendable {
    var yesterdayEnergy: Double?
    var usualEnergy: Double?
    var yesterdayExercise: Double?
    var usualExercise: Double?
    var vo2Max: Double?
    var vo2MaxDate: Date?
    /// Change since the oldest reading in the window (at least two weeks apart)
    var vo2MaxChange: Double?
}

nonisolated func makeRecoveryExtras(
    energy: [ActiveEnergySample],
    exercise: [ExerciseTimeSample],
    vo2Max: [VO2MaxSample],
    now: Date = .now,
    calendar: Calendar = .current
) -> RecoveryExtras {
    var extras = RecoveryExtras()
    let today = calendar.startOfDay(for: now)
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return extras }

    func dailyTotals(_ samples: [(date: Date, value: Double)]) -> [Date: Double] {
        samples.reduce(into: [:]) { totals, sample in
            totals[calendar.startOfDay(for: sample.date), default: 0] += sample.value
        }
    }

    // Yesterday vs. the days before it (today is still in progress)
    let energyByDay = dailyTotals(energy.map { ($0.date, $0.value) })
    extras.yesterdayEnergy = energyByDay[yesterday]
    let priorEnergy = energyByDay.filter { $0.key < yesterday }.map(\.value)
    if priorEnergy.count >= 3 { extras.usualEnergy = insightMean(priorEnergy) }

    let exerciseByDay = dailyTotals(exercise.map { ($0.date, $0.value) })
    extras.yesterdayExercise = exerciseByDay[yesterday] ?? (energyByDay[yesterday] != nil ? 0 : nil)
    let priorExercise = exerciseByDay.filter { $0.key < yesterday }.map(\.value)
    if priorExercise.count >= 3 { extras.usualExercise = insightMean(priorExercise) }

    // Samples are newest first
    if let latest = vo2Max.first {
        extras.vo2Max = latest.value
        extras.vo2MaxDate = latest.date
        if let oldest = vo2Max.last, latest.date.timeIntervalSince(oldest.date) >= 14 * 86400 {
            extras.vo2MaxChange = latest.value - oldest.value
        }
    }
    return extras
}

// MARK: - Math helpers

private nonisolated func union(_ spans: [Span]) -> [Span] {
    var merged: [Span] = []
    for span in spans.sorted(by: { $0.start < $1.start }) {
        if let last = merged.last, span.start <= last.end {
            merged[merged.count - 1].end = max(last.end, span.end)
        } else {
            merged.append(span)
        }
    }
    return merged
}

private nonisolated func totalDuration(_ spans: [Span]) -> TimeInterval {
    spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
}

private nonisolated func clip(_ span: Span, to block: Span) -> Span? {
    let start = max(span.start, block.start)
    let end = min(span.end, block.end)
    return end > start ? (start, end) : nil
}

nonisolated func insightMean(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
}

nonisolated func insightStandardDeviation(_ values: [Double]) -> Double? {
    guard values.count >= 2, let mean = insightMean(values) else { return nil }
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return variance.squareRoot()
}
