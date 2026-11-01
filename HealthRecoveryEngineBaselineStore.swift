//
//  BaselineStore.swift
//  HealthRecovery
//
//  Manages 60-day rolling baselines for each health metric
//

import Foundation
import SwiftData

actor BaselineStore {
    
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
    }
    
    // MARK: - Public API
    
    /// Update baseline for a specific metric with new samples
    func updateBaseline(metricType: String, values: [Double], date: Date = Date()) {
        // Fetch existing baseline or create new one
        let descriptor = FetchDescriptor<BaselineData>(
            predicate: #Predicate { $0.metricType == metricType }
        )
        
        let existing = try? modelContext.fetch(descriptor).first
        
        if let baseline = existing {
            // Update existing baseline
            var samples = baseline.samples
            samples.append(contentsOf: values)
            
            // Keep only last 60 days worth (approximate)
            let maxSamples = 60 * 10 // Assuming ~10 samples per day max
            if samples.count > maxSamples {
                samples = Array(samples.suffix(maxSamples))
            }
            
            baseline.samples = samples
            baseline.sampleCount = samples.count
            baseline.lastUpdated = date
            
            // Recompute statistics
            let stats = computeStatistics(samples)
            baseline.mean = stats.mean
            baseline.standardDeviation = stats.standardDeviation
            
        } else {
            // Create new baseline
            let stats = computeStatistics(values)
            let newBaseline = BaselineData(
                metricType: metricType,
                mean: stats.mean,
                standardDeviation: stats.standardDeviation,
                sampleCount: values.count,
                lastUpdated: date,
                samples: values
            )
            modelContext.insert(newBaseline)
        }
        
        try? modelContext.save()
    }
    
    /// Get baseline for a specific metric
    func getBaseline(for metricType: String) -> BaselineData? {
        let descriptor = FetchDescriptor<BaselineData>(
            predicate: #Predicate { $0.metricType == metricType }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    /// Mean and standard deviation of a baseline, if one exists
    func statistics(for metricType: String) -> (mean: Double, standardDeviation: Double)? {
        guard let baseline = getBaseline(for: metricType) else { return nil }
        return (baseline.mean, baseline.standardDeviation)
    }

    /// Compute z-score for a value against its baseline
    func zScore(for metricType: String, value: Double) -> Double? {
        guard let baseline = getBaseline(for: metricType),
              baseline.standardDeviation > 0 else {
            return nil
        }
        
        return (value - baseline.mean) / baseline.standardDeviation
    }
    
    /// Get all baselines
    func getAllBaselines() -> [BaselineData] {
        let descriptor = FetchDescriptor<BaselineData>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    /// Clear baseline for a specific metric (useful for testing/reset)
    func clearBaseline(for metricType: String) {
        let descriptor = FetchDescriptor<BaselineData>(
            predicate: #Predicate { $0.metricType == metricType }
        )
        
        if let baseline = try? modelContext.fetch(descriptor).first {
            modelContext.delete(baseline)
            try? modelContext.save()
        }
    }
    
    /// Clear all baselines
    func clearAllBaselines() {
        let descriptor = FetchDescriptor<BaselineData>()
        let allBaselines = (try? modelContext.fetch(descriptor)) ?? []
        
        for baseline in allBaselines {
            modelContext.delete(baseline)
        }
        
        try? modelContext.save()
    }
    
    // MARK: - Helper: Compute daily aggregates
    
    /// Process samples into daily aggregates (useful for metrics with many samples per day)
    func updateBaselineWithDailyAggregates(
        metricType: String,
        samples: [(date: Date, value: Double)],
        aggregation: AggregationType = .mean
    ) {
        // Group by day
        let calendar = Calendar.current
        var dailyGroups: [Date: [Double]] = [:]
        
        for sample in samples {
            let day = calendar.startOfDay(for: sample.date)
            dailyGroups[day, default: []].append(sample.value)
        }
        
        // Aggregate each day
        let dailyValues = dailyGroups.map { _, values -> Double in
            switch aggregation {
            case .mean:
                return values.reduce(0, +) / Double(values.count)
            case .median:
                let sorted = values.sorted()
                let mid = sorted.count / 2
                return sorted.count % 2 == 0
                    ? (sorted[mid - 1] + sorted[mid]) / 2
                    : sorted[mid]
            case .max:
                return values.max() ?? 0
            case .min:
                return values.min() ?? 0
            }
        }
        
        updateBaseline(metricType: metricType, values: dailyValues)
    }
    
    // MARK: - Private Helpers
    
    private func computeStatistics(_ values: [Double]) -> (mean: Double, standardDeviation: Double) {
        guard !values.isEmpty else {
            return (0, 0)
        }
        
        let mean = values.reduce(0, +) / Double(values.count)
        
        let variance = values.reduce(0) { sum, value in
            let diff = value - mean
            return sum + (diff * diff)
        } / Double(values.count)
        
        let standardDeviation = sqrt(variance)
        
        return (mean, standardDeviation)
    }
}

// MARK: - Supporting Types

enum AggregationType {
    case mean
    case median
    case max
    case min
}

// MARK: - Metric Type Constants

enum MetricType {
    static let hrv = "HRV"
    static let restingHR = "RestingHR"
    static let sleep = "Sleep"
    static let respiratoryRate = "RespiratoryRate"
    static let wristTemp = "WristTemp"
    static let activeEnergy = "ActiveEnergy"
    static let exerciseTime = "ExerciseTime"
    static let vo2Max = "VO2Max"
    static let bloodOxygen = "BloodOxygen"
}
