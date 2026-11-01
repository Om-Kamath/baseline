//
//  RecoveryScore.swift
//  HealthRecovery
//
//  SwiftData model for daily recovery scores
//

import Foundation
import SwiftData

@Model
final class RecoveryScore {
    @Attribute(.unique) var date: Date // Normalized to start of day
    var score: Double // 0-100
    var contributions: [String: Double] // Metric name -> point contribution
    var metricZScores: [String: Double] // Metric name -> z-score
    var computedAt: Date

    /// JSON-encoded `[String: MetricReading]`: the values each metric was scored on.
    /// Optional so scores saved by earlier versions still load.
    var metricReadingsData: Data?

    /// The values each metric was scored on, keyed like `metricZScores`.
    var metricReadings: [String: MetricReading] {
        get {
            guard let metricReadingsData else { return [:] }
            return (try? JSONDecoder().decode([String: MetricReading].self, from: metricReadingsData)) ?? [:]
        }
        set {
            metricReadingsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(
        date: Date,
        score: Double,
        contributions: [String: Double],
        metricZScores: [String: Double],
        computedAt: Date,
        metricReadings: [String: MetricReading] = [:]
    ) {
        self.date = date
        self.score = score
        self.contributions = contributions
        self.metricZScores = metricZScores
        self.computedAt = computedAt
        self.metricReadingsData = try? JSONEncoder().encode(metricReadings)
    }
}

/// What a metric was scored on, in display units (ms, bpm, hours, …).
struct MetricReading: Codable, Sendable {
    /// The value compared with the baseline
    let value: Double
    /// Describes `value`, e.g. "7-day avg" or "Last night"
    let valueLabel: String
    /// Your usual value and typical range (usual ± 1 standard deviation)
    let usual: Double
    let rangeLow: Double
    let rangeHigh: Double
    /// Optional explanation, e.g. why a metric wasn't penalized
    var note: String? = nil
}
