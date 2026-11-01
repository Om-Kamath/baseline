//
//  RecoveryScorer.swift
//  HealthRecovery
//
//  Computes daily recovery score (0-100) using z-scores and weighted metrics
//

import Foundation
import SwiftData

actor RecoveryScorer {
    
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext
    private let healthKitManager: HealthKitManager
    private let baselineStore: BaselineStore
    
    init(healthKitManager: HealthKitManager, modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.healthKitManager = healthKitManager
        self.baselineStore = BaselineStore(modelContainer: modelContainer)
    }
    
    // MARK: - Compute Recovery Score
    
    /// Compute recovery score for a specific date (typically today)
    func computeRecoveryScore(for date: Date = Date()) async throws -> RecoveryScoreResult {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        
        // HRV and resting HR are scored on 7-day trends against 60 days of history.
        // Sleep covers the same span because HRV is read from each night's sleep.
        let historyDays = 60
        let sleepSamples = try await healthKitManager.fetchSleep(days: historyDays)
        let hrvSamples = try await healthKitManager.fetchHRV(days: historyDays)
        let restingHRSamples = try await healthKitManager.fetchRestingHeartRate(days: historyDays)

        // Respiratory rate and wrist temp use the latest reading
        let respiratorySamples = try await healthKitManager.fetchRespiratoryRate(days: 2)
        let tempSamples = try await healthKitManager.fetchWristTemperature(days: 2)

        // 1. HRV (40% weight)
        let hrvContribution = computeHRVContribution(
            samples: hrvSamples,
            sleepSamples: sleepSamples,
            targetDate: startOfDay
        )
        
        // 2. Resting HR (20% weight, inverted)
        let restingHRContribution = computeRestingHRContribution(samples: restingHRSamples, targetDate: startOfDay)
        
        // 3. Sleep (25% weight)
        let sleepContribution = await computeSleepContribution(
            samples: sleepSamples,
            targetDate: startOfDay,
            lastNightHRVZ: hrvContribution.lastNightZ
        )
        
        // 4. Respiratory rate + wrist temp (15% weight)
        let respTempContribution = await computeRespiratoryTempContribution(
            respiratorySamples: respiratorySamples,
            tempSamples: tempSamples
        )
        
        // Combine scores
        let totalScore = max(0, min(100,
            hrvContribution.score +
            restingHRContribution.score +
            sleepContribution.score +
            respTempContribution.score
        ))
        
        // Build result
        let contributions: [String: Double] = [
            "HRV": hrvContribution.score,
            "Resting HR": restingHRContribution.score,
            "Sleep": sleepContribution.score,
            "Respiratory & Temp": respTempContribution.score
        ]
        
        let zScores: [String: Double] = [
            "HRV": hrvContribution.zScore ?? 0,
            "Resting HR": restingHRContribution.zScore ?? 0,
            "Sleep": sleepContribution.zScore ?? 0,
            "Respiratory Rate": respTempContribution.respiratoryZScore ?? 0,
            "Wrist Temp": respTempContribution.tempZScore ?? 0
        ]

        var readings: [String: MetricReading] = [:]
        readings["HRV"] = hrvContribution.reading
        readings["Resting HR"] = restingHRContribution.reading
        readings["Sleep"] = sleepContribution.reading
        readings["Respiratory Rate"] = respTempContribution.respiratoryReading
        readings["Wrist Temp"] = respTempContribution.tempReading
        
        // Save to SwiftData
        let recoveryScore = RecoveryScore(
            date: startOfDay,
            score: totalScore,
            contributions: contributions,
            metricZScores: zScores,
            computedAt: Date(),
            metricReadings: readings
        )
        
        modelContext.insert(recoveryScore)
        try? modelContext.save()
        
        return RecoveryScoreResult(
            date: startOfDay,
            totalScore: totalScore,
            contributions: contributions,
            zScores: zScores
        )
    }
    
    // MARK: - Get Historical Scores
    
    /// Fetch recovery scores for the last N days
    func getRecoveryScores(lastDays: Int) -> [RecoveryScore] {
        let startDate = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date())!
        
        let descriptor = FetchDescriptor<RecoveryScore>(
            predicate: #Predicate { $0.date >= startDate },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    /// Get today's recovery score (if computed)
    func getTodayScore() -> RecoveryScore? {
        let today = Calendar.current.startOfDay(for: Date())
        
        let descriptor = FetchDescriptor<RecoveryScore>(
            predicate: #Predicate { $0.date == today }
        )
        
        return try? modelContext.fetch(descriptor).first
    }
    
    // MARK: - Private: Contribution Calculators
    
    private func computeHRVContribution(
        samples: [HRVSample],
        sleepSamples: [SleepSample],
        targetDate: Date
    ) -> MetricContribution {
        let neutral = MetricContribution(score: 50 * ScoringWeights.hrvWeight, zScore: nil)

        // One value per night from readings taken during sleep (deep sleep preferred).
        // If the watch isn't usually worn to bed, fall back to daily averages.
        var nightly = sleepSamples.overnightHRVByNight(samples)
        var label = "7-night avg"
        if nightly.count < 14 {
            nightly = dailyAverages(samples.map { ($0.date, $0.value) })
            label = "7-day avg"
        }

        // HRV is right-skewed (one unusually high night would distort the average and
        // spread), so it's analyzed as a natural log, as in HRV research
        let logged = nightly.filter { $0.value > 0 }.mapValues { Foundation.log($0) }
        guard let trend = rollingTrend(logged, endingOn: targetDate) else { return neutral }

        let reading = MetricReading(
            value: exp(trend.current),
            valueLabel: label,
            usual: exp(trend.mean),
            rangeLow: exp(trend.mean - trend.standardDeviation),
            rangeHigh: exp(trend.mean + trend.standardDeviation)
        )

        // HRV: higher is better
        return MetricContribution(
            score: pointsFromZ(trend.z) * ScoringWeights.hrvWeight,
            zScore: trend.z,
            reading: reading,
            lastNightZ: logged[targetDate].map { trend.dailyZ($0) }
        )
    }
    
    private func computeRestingHRContribution(samples: [RestingHRSample], targetDate: Date) -> MetricContribution {
        let daily = dailyAverages(samples.map { ($0.date, $0.value) })
        guard let trend = rollingTrend(daily, endingOn: targetDate) else {
            return MetricContribution(score: 50 * ScoringWeights.restingHRWeight, zScore: nil)
        }

        let reading = MetricReading(
            value: trend.current,
            valueLabel: "7-day avg",
            usual: trend.mean,
            rangeLow: trend.mean - trend.standardDeviation,
            rangeHigh: trend.mean + trend.standardDeviation
        )
        
        // Resting HR: LOWER is better (inverted)
        return MetricContribution(
            score: pointsFromZ(-trend.z) * ScoringWeights.restingHRWeight,
            zScore: trend.z,
            reading: reading
        )
    }
    
    private func computeSleepContribution(
        samples: [SleepSample],
        targetDate: Date,
        lastNightHRVZ: Double?
    ) async -> MetricContribution {
        // Last night's sleep (6 PM yesterday to 6 PM today), with overlapping sources merged
        guard let sleepHours = samples.sleepHours(forNightEnding: targetDate) else {
            return MetricContribution(score: 30 * ScoringWeights.sleepWeight, zScore: nil) // Low score for no sleep data
        }

        var points: Double
        var zScore: Double?
        var reading: MetricReading?

        if let stats = await baselineStore.statistics(for: MetricType.sleep), stats.standardDeviation > 0 {
            // Sleep: higher is better (like HRV)
            let z = (sleepHours - stats.mean) / stats.standardDeviation
            points = pointsFromZ(z)
            zScore = z
            reading = MetricReading(
                value: sleepHours,
                valueLabel: "Last night",
                usual: stats.mean,
                rangeLow: stats.mean - stats.standardDeviation,
                rangeHigh: stats.mean + stats.standardDeviation
            )
        } else {
            // No baseline, use absolute scoring
            points = scoreSleepAbsolute(hours: sleepHours)
        }

        // Short sleep usually lowers HRV too, so penalizing both would count the same
        // night twice. If HRV stayed normal, the body coped and sleep isn't penalized.
        if points < 50, let lastNightHRVZ, lastNightHRVZ >= -ScoringWeights.trivialZ {
            points = 50
            reading?.note = "Not penalized: your HRV stayed normal last night, so your body handled the shorter sleep."
        }
        
        return MetricContribution(score: points * ScoringWeights.sleepWeight, zScore: zScore, reading: reading)
    }
    
    private func computeRespiratoryTempContribution(
        respiratorySamples: [RespiratoryRateSample],
        tempSamples: [WristTemperatureSample]
    ) async -> RespTempContribution {
        // Deviation from baseline in either direction is bad, so these score 100 when
        // normal and lose points beyond the normal zone
        let resp = await deviationScore(latest: respiratorySamples.first?.value, metricType: MetricType.respiratoryRate)
        let temp = await deviationScore(latest: tempSamples.first?.value, metricType: MetricType.wristTemp)

        // Average the two and apply weight
        let avgScore = (resp.points + temp.points) / 2
        let weightedScore = avgScore * ScoringWeights.respiratoryAndTempWeight
        
        return RespTempContribution(
            score: weightedScore,
            respiratoryZScore: resp.zScore,
            tempZScore: temp.zScore,
            respiratoryReading: resp.reading,
            tempReading: temp.reading
        )
    }

    /// Points (0–100) for a metric where any deviation from usual is bad. Neutral (50)
    /// when there's no reading or baseline.
    private func deviationScore(
        latest value: Double?,
        metricType: String
    ) async -> (points: Double, zScore: Double?, reading: MetricReading?) {
        guard let value,
              let stats = await baselineStore.statistics(for: metricType),
              stats.standardDeviation > 0 else {
            return (50, nil, nil)
        }

        let z = (value - stats.mean) / stats.standardDeviation
        let beyondNormal = max(0, abs(z) - ScoringWeights.trivialZ)
        let points = max(0, 100 - beyondNormal * ScoringWeights.pointsPerStandardDeviation)
        let reading = MetricReading(
            value: value,
            valueLabel: "Latest",
            usual: stats.mean,
            rangeLow: stats.mean - stats.standardDeviation,
            rangeHigh: stats.mean + stats.standardDeviation
        )
        return (points, z, reading)
    }

    /// Average value per calendar day.
    private func dailyAverages(_ samples: [(date: Date, value: Double)]) -> [Date: Double] {
        let calendar = Calendar.current
        var byDay: [Date: [Double]] = [:]
        for sample in samples {
            byDay[calendar.startOfDay(for: sample.date), default: []].append(sample.value)
        }
        return byDay.mapValues { $0.reduce(0, +) / Double($0.count) }
    }
    
    private func scoreSleepAbsolute(hours: Double) -> Double {
        // Absolute scoring when no baseline exists
        // Optimal: 7-9 hours = 100 points
        // 6 hours = 75, 5 hours = 50, <4 hours = 25
        
        switch hours {
        case 7...9:
            return 100
        case 6..<7:
            return 75 + ((hours - 6) * 25)
        case 5..<6:
            return 50 + ((hours - 5) * 25)
        case 4..<5:
            return 25 + ((hours - 4) * 25)
        default:
            return hours < 4 ? 25 : 100
        }
    }
}

// MARK: - Supporting Types

struct RecoveryScoreResult {
    let date: Date
    let totalScore: Double
    let contributions: [String: Double]
    let zScores: [String: Double]
}

/// 0–100 points for a z-score where higher is better.
///
/// Scores 50 at your usual level, doesn't move inside the "normal" zone (±`trivialZ`,
/// treated as day-to-day noise), then moves `pointsPerStandardDeviation` per SD beyond it.
private nonisolated func pointsFromZ(_ z: Double) -> Double {
    let beyondNormal = max(0, abs(z) - ScoringWeights.trivialZ)
    let signed = z < 0 ? -beyondNormal : beyondNormal
    return max(0, min(100, 50 + signed * ScoringWeights.pointsPerStandardDeviation))
}

private struct MetricContribution {
    let score: Double
    let zScore: Double?
    var reading: MetricReading? = nil
    /// HRV only: last night's single-night z-score, used to decide the sleep penalty
    var lastNightZ: Double? = nil
}

private struct RespTempContribution {
    let score: Double
    let respiratoryZScore: Double?
    let tempZScore: Double?
    let respiratoryReading: MetricReading?
    let tempReading: MetricReading?
}
