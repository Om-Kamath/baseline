//
//  HealthMetrics.swift
//  HealthRecovery
//
//  Typed structs for HealthKit samples
//

import Foundation

/// HRV (SDNN) in milliseconds
struct HRVSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // ms
}

/// Resting heart rate in BPM
struct RestingHRSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // BPM
}

/// Heart rate sample in BPM
struct HeartRateSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // BPM
}

/// Sleep analysis with duration and quality
struct SleepSample: Identifiable, Sendable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let value: SleepStage
    
    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
    
    enum SleepStage: Sendable {
        case inBed
        case asleepCore
        case asleepDeep
        case asleepREM
        case awake
    }
}

/// Respiratory rate in breaths per minute
struct RespiratoryRateSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // breaths/min
}

/// Wrist temperature delta from baseline (Celsius)
struct WristTemperatureSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // °C delta
}

/// Active energy burned in kcal
struct ActiveEnergySample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // kcal
}

/// Exercise time in minutes
struct ExerciseTimeSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // minutes
}

/// Workout session
struct WorkoutSample: Identifiable, Sendable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let activityType: String
    let duration: TimeInterval
    let totalEnergyBurned: Double? // kcal

    /// SF Symbol for the activity type
    var symbolName: String {
        switch activityType {
        case "Running": "figure.run"
        case "Walking": "figure.walk"
        case "Cycling": "figure.outdoor.cycle"
        case "Swimming": "figure.pool.swim"
        case "Hiking": "figure.hiking"
        case "Yoga": "figure.yoga"
        case "Strength Training", "Core Training": "dumbbell.fill"
        case "Elliptical": "figure.elliptical"
        case "Rowing": "figure.rower"
        case "Stairs": "figure.stairs"
        case "Kickboxing": "figure.kickboxing"
        case "Dance": "figure.dance"
        default: "figure.mixed.cardio"
        }
    }

    /// "Workout" instead of "Other" for unrecognized activity types
    var displayName: String {
        activityType == "Other" ? "Workout" : activityType
    }
}

/// VO2 max in mL/kg/min
struct VO2MaxSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // mL/kg/min
}

/// Blood oxygen saturation (%)
struct BloodOxygenSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double // percentage (0-100)
}

// MARK: - Sleep aggregation

extension Array where Element == SleepSample {

    /// Asleep time per night, merged into non-overlapping intervals and keyed by the
    /// start of the day the night ends on.
    ///
    /// A "night" runs from 6 PM the previous day to 6 PM, so sleep that starts in the
    /// evening and sleep after midnight count toward the same morning. Overlapping
    /// samples (e.g. from an Apple Watch and another sleep app) are merged so the same
    /// time isn't counted twice. Intervals separated by less than `joiningGap` are joined
    /// (useful for bridging brief awakenings between sleep stages).
    nonisolated func asleepIntervalsByNight(
        joiningGap: TimeInterval = 0,
        calendar: Calendar = .current
    ) -> [Date: [(start: Date, end: Date)]] {
        var intervalsByNight: [Date: [(start: Date, end: Date)]] = [:]

        for sample in self {
            switch sample.value {
            case .asleepCore, .asleepDeep, .asleepREM:
                let night = sleepNightKey(for: sample.startDate, calendar: calendar)
                intervalsByNight[night, default: []].append((sample.startDate, sample.endDate))
            case .inBed, .awake:
                continue
            }
        }

        return intervalsByNight.mapValues { mergedIntervals($0, joiningGap: joiningGap) }
    }

    /// Total hours asleep per night (see `asleepIntervalsByNight`).
    nonisolated func nightlySleepHours(calendar: Calendar = .current) -> [Date: Double] {
        asleepIntervalsByNight(calendar: calendar).mapValues { intervals in
            intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
        }
    }

    /// Hours asleep for the night ending on `day`, or `nil` if there's no sleep data for it.
    nonisolated func sleepHours(forNightEnding day: Date, calendar: Calendar = .current) -> Double? {
        nightlySleepHours(calendar: calendar)[calendar.startOfDay(for: day)]
    }

    /// Average HRV of readings taken while asleep, per night.
    ///
    /// Overnight readings are taken under similar, controlled conditions every night,
    /// so they're far less affected by movement, caffeine, or stress than daytime
    /// spot readings. Readings from deep (slow-wave) sleep are preferred when a night
    /// has at least two of them: that stage has the most stable heart rhythm, while
    /// broken-up lighter sleep can inflate HRV.
    nonisolated func overnightHRVByNight(_ hrv: [HRVSample], calendar: Calendar = .current) -> [Date: Double] {
        // Bridge short awakenings so readings between sleep stages still count
        let nights = asleepIntervalsByNight(joiningGap: 30 * 60, calendar: calendar)
        let deepNights = deepSleepIntervalsByNight(calendar: calendar)
        var allByNight: [Date: [Double]] = [:]
        var deepByNight: [Date: [Double]] = [:]

        for sample in hrv {
            let night = sleepNightKey(for: sample.date, calendar: calendar)
            guard let intervals = nights[night], covers(intervals, sample.date) else {
                continue
            }
            allByNight[night, default: []].append(sample.value)

            if let deep = deepNights[night], covers(deep, sample.date) {
                deepByNight[night, default: []].append(sample.value)
            }
        }

        var averages: [Date: Double] = [:]
        for (night, all) in allByNight {
            let deep = deepByNight[night] ?? []
            let readings = deep.count >= 2 ? deep : all
            averages[night] = readings.reduce(0, +) / Double(readings.count)
        }
        return averages
    }

    /// Deep-sleep intervals per night, with brief gaps (under 5 minutes) bridged.
    private nonisolated func deepSleepIntervalsByNight(calendar: Calendar) -> [Date: [(start: Date, end: Date)]] {
        var intervalsByNight: [Date: [(start: Date, end: Date)]] = [:]
        for sample in self {
            guard case .asleepDeep = sample.value else { continue }
            let night = sleepNightKey(for: sample.startDate, calendar: calendar)
            intervalsByNight[night, default: []].append((sample.startDate, sample.endDate))
        }
        return intervalsByNight.mapValues { mergedIntervals($0, joiningGap: 5 * 60) }
    }
}

/// Whether any of the intervals covers the given moment.
private nonisolated func covers(_ intervals: [(start: Date, end: Date)], _ date: Date) -> Bool {
    intervals.contains { $0.start <= date && date <= $0.end }
}

// MARK: - Rolling trends

/// A recent rolling average of a daily series compared with that series' own history.
///
/// Day-to-day readings are noisy (HRV can swing 10–20% from one night to the next),
/// so readiness research compares a multi-day average with your usual level, and
/// measures the difference against the spread of *single days*. Half that spread is
/// the commonly used "smallest worthwhile change".
struct RollingTrend: Sendable {
    /// Rolling average ending on the target day
    let current: Double
    /// Mean and standard deviation of single days over the history
    let mean: Double
    let standardDeviation: Double

    nonisolated var z: Double { (current - mean) / standardDeviation }

    /// z-score of a single day's value
    nonisolated func dailyZ(_ value: Double) -> Double {
        (value - mean) / standardDeviation
    }
}

/// Builds a `RollingTrend` from one value per day (keyed by start of day).
///
/// Returns `nil` if there's too little history, or the window ending on `day` has
/// fewer than `minimumDaysInWindow` values.
nonisolated func rollingTrend(
    _ daily: [Date: Double],
    endingOn day: Date,
    window: Int = 7,
    minimumDaysInWindow: Int = 3,
    minimumHistory: Int = 14,
    calendar: Calendar = .current
) -> RollingTrend? {
    let target = calendar.startOfDay(for: day)
    let days = daily.keys.filter { $0 <= target }.sorted()
    guard days.count >= minimumHistory,
          let windowStart = calendar.date(byAdding: .day, value: -(window - 1), to: target) else {
        return nil
    }

    let recent = days.filter { $0 >= windowStart }.compactMap { daily[$0] }
    guard recent.count >= minimumDaysInWindow else { return nil }

    let (mean, sd) = meanAndStandardDeviation(days.compactMap { daily[$0] })
    guard sd > 0 else { return nil }

    return RollingTrend(
        current: recent.reduce(0, +) / Double(recent.count),
        mean: mean,
        standardDeviation: sd
    )
}

private nonisolated func meanAndStandardDeviation(_ values: [Double]) -> (Double, Double) {
    guard !values.isEmpty else { return (0, 0) }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return (mean, variance.squareRoot())
}

/// The night a moment belongs to: shifting by 6 hours moves the 6 PM boundary to midnight.
nonisolated func sleepNightKey(for date: Date, calendar: Calendar = .current) -> Date {
    calendar.startOfDay(for: date.addingTimeInterval(6 * 3600))
}

/// Merges overlapping intervals (and those separated by less than `joiningGap`).
private nonisolated func mergedIntervals(
    _ intervals: [(start: Date, end: Date)],
    joiningGap: TimeInterval
) -> [(start: Date, end: Date)] {
    let sorted = intervals.sorted { $0.start < $1.start }
    var merged: [(start: Date, end: Date)] = []

    for interval in sorted {
        if let last = merged.last, interval.start.timeIntervalSince(last.end) <= joiningGap {
            merged[merged.count - 1].end = Swift.max(last.end, interval.end)
        } else {
            merged.append(interval)
        }
    }
    return merged
}
