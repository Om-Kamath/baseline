//
//  BaselineBuilder.swift
//  HealthRecovery
//
//  Coordinates fetching health data and building baselines
//

import Foundation
import SwiftData

actor BaselineBuilder {
    
    private let healthKitManager: HealthKitManager
    private let baselineStore: BaselineStore

    /// Start of the day baselines were last rebuilt
    private static let lastRebuildKey = "baselinesLastRebuiltDay"

    init(healthKitManager: HealthKitManager, modelContainer: ModelContainer) {
        self.healthKitManager = healthKitManager
        self.baselineStore = BaselineStore(modelContainer: modelContainer)
    }
    
    // MARK: - Build All Baselines
    
    /// Fetch 60 days of data from HealthKit and add it to the baselines.
    /// Use `refreshBaselinesIfNeeded` to rebuild from scratch.
    func buildAllBaselines() async throws {
        let days = 60
        
        // HRV (overnight average per night)
        let hrvSamples = try await healthKitManager.fetchHRV(days: days)
        let hrvSleepSamples = try await healthKitManager.fetchSleep(days: days)
        await updateHRVBaseline(hrvSamples, sleep: hrvSleepSamples)
        
        // Resting HR
        let restingHRSamples = try await healthKitManager.fetchRestingHeartRate(days: days)
        if !restingHRSamples.isEmpty {
            await baselineStore.updateBaselineWithDailyAggregates(
                metricType: MetricType.restingHR,
                samples: restingHRSamples.map { ($0.date, $0.value) },
                aggregation: .mean
            )
        }
        
        // Sleep duration (total per night)
        let sleepSamples = try await healthKitManager.fetchSleep(days: days)
        if !sleepSamples.isEmpty {
            let sleepDurations = aggregateSleepDuration(sleepSamples)
            await baselineStore.updateBaseline(
                metricType: MetricType.sleep,
                values: sleepDurations
            )
        }
        
        // Respiratory rate
        let respiratorySamples = try await healthKitManager.fetchRespiratoryRate(days: days)
        if !respiratorySamples.isEmpty {
            await baselineStore.updateBaselineWithDailyAggregates(
                metricType: MetricType.respiratoryRate,
                samples: respiratorySamples.map { ($0.date, $0.value) },
                aggregation: .mean
            )
        }
        
        // Wrist temperature
        let tempSamples = try await healthKitManager.fetchWristTemperature(days: days)
        if !tempSamples.isEmpty {
            await baselineStore.updateBaselineWithDailyAggregates(
                metricType: MetricType.wristTemp,
                samples: tempSamples.map { ($0.date, $0.value) },
                aggregation: .mean
            )
        }
        
        // Active energy
        let energySamples = try await healthKitManager.fetchActiveEnergy(days: days)
        if !energySamples.isEmpty {
            await baselineStore.updateBaselineWithDailyAggregates(
                metricType: MetricType.activeEnergy,
                samples: energySamples.map { ($0.date, $0.value) },
                aggregation: .mean
            )
        }
        
        // Exercise time
        let exerciseSamples = try await healthKitManager.fetchExerciseTime(days: days)
        if !exerciseSamples.isEmpty {
            await baselineStore.updateBaselineWithDailyAggregates(
                metricType: MetricType.exerciseTime,
                samples: exerciseSamples.map { ($0.date, $0.value) },
                aggregation: .mean
            )
        }
        
        // VO2 max
        let vo2Samples = try await healthKitManager.fetchVO2Max(days: days)
        if !vo2Samples.isEmpty {
            await baselineStore.updateBaseline(
                metricType: MetricType.vo2Max,
                values: vo2Samples.map { $0.value }
            )
        }
        
        // Blood oxygen
        let oxygenSamples = try await healthKitManager.fetchBloodOxygen(days: days)
        if !oxygenSamples.isEmpty {
            await baselineStore.updateBaselineWithDailyAggregates(
                metricType: MetricType.bloodOxygen,
                samples: oxygenSamples.map { ($0.date, $0.value) },
                aggregation: .mean
            )
        }
    }
    
    // MARK: - Daily Refresh

    /// Rebuilds every baseline from the last 60 days, at most once per day.
    ///
    /// Baselines are rebuilt from scratch instead of appended to, so refreshing
    /// repeatedly never adds the same days twice.
    func refreshBaselinesIfNeeded(force: Bool = false) async throws {
        let today = Calendar.current.startOfDay(for: Date())
        if !force,
           let lastRebuild = UserDefaults.standard.object(forKey: Self.lastRebuildKey) as? Date,
           lastRebuild >= today {
            return
        }

        await baselineStore.clearAllBaselines()
        try await buildAllBaselines()
        UserDefaults.standard.set(today, forKey: Self.lastRebuildKey)
    }
    
    // MARK: - Helpers

    /// HRV baseline from the average of readings taken during each night's sleep.
    /// Falls back to daily averages if there are no overnight readings at all
    /// (e.g. the watch isn't worn to bed).
    private func updateHRVBaseline(_ hrv: [HRVSample], sleep: [SleepSample]) async {
        let overnight = sleep.overnightHRVByNight(hrv)

        if !overnight.isEmpty {
            await baselineStore.updateBaseline(
                metricType: MetricType.hrv,
                values: overnight.keys.sorted().compactMap { overnight[$0] }
            )
        } else if !hrv.isEmpty {
            await baselineStore.updateBaselineWithDailyAggregates(
                metricType: MetricType.hrv,
                samples: hrv.map { ($0.date, $0.value) },
                aggregation: .mean
            )
        }
    }
    
    /// Hours asleep per night (6 PM to 6 PM, overlapping sources merged).
    private func aggregateSleepDuration(_ samples: [SleepSample]) -> [Double] {
        let nightly = samples.nightlySleepHours()

        // The oldest night is usually cut off by the fetch window, so leave it out
        let nights = nightly.keys.sorted().dropFirst(nightly.count > 1 ? 1 : 0)
        return nights.compactMap { nightly[$0] }
    }
}
