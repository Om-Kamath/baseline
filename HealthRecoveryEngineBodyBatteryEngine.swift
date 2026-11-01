//
//  BodyBatteryEngine.swift
//  HealthRecovery
//
//  Continuous body battery simulation: starts at morning recovery score,
//  drains with activity, recharges during rest and sleep
//

import Foundation
import SwiftData

actor BodyBatteryEngine {
    
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext
    private let healthKitManager: HealthKitManager
    
    init(healthKitManager: HealthKitManager, modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.healthKitManager = healthKitManager
    }
    
    // MARK: - Initialize Day
    
    /// Start the day's battery at the morning recovery score.
    ///
    /// The starting point is anchored at wake-up time rather than midnight: the recovery
    /// score already reflects last night's sleep, so recharging for that sleep again
    /// would double-count it. Does nothing if today's battery has already been started.
    func initializeDayBattery(startingScore: Double, date: Date = Date()) async {
        guard getTodayStartSnapshot(now: date) == nil else { return }

        // Any snapshots already saved today were carried over from a previous day's
        // battery, so they're replaced by the fresh start.
        for snapshot in getTodayBattery() {
            modelContext.delete(snapshot)
        }

        let wakeTime = await wakeTime(on: date) ?? date

        let snapshot = BodyBatterySnapshot(
            timestamp: wakeTime,
            level: startingScore,
            reason: "morning_recovery"
        )

        modelContext.insert(snapshot)
        try? modelContext.save()
    }

    // MARK: - Update Battery

    /// Update battery level based on recent heart rate data
    func updateBattery(from startTime: Date? = nil) async throws {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // Each day starts fresh from that day's recovery score. If today hasn't started
        // yet, start it now (this also covers background updates).
        if getTodayStartSnapshot(now: now) == nil {
            guard let todayScore = getRecoveryScore(for: startOfToday) else {
                // No recovery score for today yet - nothing to start from
                return
            }
            await initializeDayBattery(startingScore: todayScore, date: now)
        }

        // Get last battery snapshot; never carry a previous day's level forward
        guard let lastSnapshot = getLatestBatterySnapshot(),
              lastSnapshot.timestamp >= startOfToday else {
            return
        }
        
        let startTime = startTime ?? lastSnapshot.timestamp
        
        // Fetch heart rate data since last update
        let hoursSinceUpdate = now.timeIntervalSince(startTime) / 3600
        guard hoursSinceUpdate > 0 else { return }
        
        // A week of heart rate and sleep is needed to learn your calm daytime heart rate
        let daysToFetch = max(7, Int(ceil(hoursSinceUpdate / 24)))
        let heartRateSamples = try await healthKitManager.fetchHeartRate(days: daysToFetch)
        let restingHRSamples = try await healthKitManager.fetchRestingHeartRate(days: 7)
        let sleepSamples = try await healthKitManager.fetchSleep(days: daysToFetch)
        
        // Get resting HR baseline
        guard let restingHR = restingHRSamples.first?.value else {
            return // Can't compute without resting HR
        }

        // Merged sleep periods; short awakenings between stages are bridged so they
        // don't break up a night
        let asleepIntervals = sleepSamples
            .asleepIntervalsByNight(joiningGap: 30 * 60)
            .values
            .flatMap { $0 }

        // Drain and recharge are measured against your calm *awake* heart rate, not
        // resting HR (which is measured at your calmest and is usually well below
        // seated, awake heart rate)
        let calmHR = calmAwakeHeartRate(
            heartRateSamples,
            asleepIntervals: asleepIntervals,
            restingHR: restingHR
        )
        
        // Filter HR samples since last update
        let recentHR = heartRateSamples.filter { $0.date >= startTime && $0.date <= now }

        // Workouts get snapshots at their start and end so their battery cost can be
        // shown exactly. Their drain itself comes from heart rate like any activity.
        let workouts = (try? await healthKitManager.fetchWorkouts(days: daysToFetch)) ?? []
        
        // Process in time chunks (e.g., 15-minute intervals)
        let intervalMinutes = 15.0
        let intervalSeconds = intervalMinutes * 60
        
        var currentBattery = lastSnapshot.level
        var currentTime = startTime

        // Recharge ramps up gradually after effort or stress instead of resuming instantly
        var minutesSinceEffort = Double.infinity
        
        while currentTime < now {
            let nextTime = currentTime.addingTimeInterval(intervalSeconds)
            
            // Get HR samples in this interval
            let intervalSamples = recentHR.filter { sample in
                sample.date >= currentTime && sample.date < nextTime
            }
            
            // Check if sleeping
            let isSleeping = asleepIntervals.contains { interval in
                interval.start <= currentTime && interval.end >= nextTime
            }

            if workouts.contains(where: { $0.startDate >= currentTime && $0.startDate < nextTime }) {
                saveSnapshot(timestamp: currentTime, level: currentBattery, reason: "workout_start")
            }
            
            if isSleeping {
                // Sleep recharge
                let rechargeRate = ScoringWeights.batterySleepRechargeRate
                let recharge = (rechargeRate * intervalMinutes) / 60
                currentBattery = min(100, currentBattery + recharge)
                minutesSinceEffort = .infinity
                
            } else if !intervalSamples.isEmpty {
                // Calculate average HR in this interval
                let avgHR = intervalSamples.map { $0.value }.reduce(0, +) / Double(intervalSamples.count)
                let hrAboveCalm = avgHR - calmHR
                
                if hrAboveCalm <= ScoringWeights.calmHRToleranceBPM {
                    // Calm - recharge, scaled down shortly after effort
                    minutesSinceEffort += intervalMinutes
                    let rampFactor = min(1, minutesSinceEffort / ScoringWeights.batteryRechargeRampMinutes)
                    let rechargeRate = ScoringWeights.batteryRechargeRateLowHR * rampFactor
                    let recharge = (rechargeRate * intervalMinutes) / 60
                    currentBattery = min(100, currentBattery + recharge)
                    
                } else {
                    // Activity or stress - drain in proportion to how far above calm
                    let drainRate = ScoringWeights.batteryDrainRatePerBPMAboveCalm
                    let drain = (hrAboveCalm * drainRate * intervalMinutes) / 60
                    currentBattery = max(0, currentBattery - drain)
                    minutesSinceEffort = 0
                }
            } else {
                minutesSinceEffort += intervalMinutes
            }
            
            // Snapshot at workout ends and every hour so the chart shows the day's shape
            // (the final level is saved below)
            if nextTime < now {
                if workouts.contains(where: { $0.endDate > currentTime && $0.endDate <= nextTime }) {
                    saveSnapshot(timestamp: nextTime, level: currentBattery, reason: "workout_end")
                } else if Int(nextTime.timeIntervalSince(startTime)) % 3600 == 0 {
                    saveSnapshot(timestamp: nextTime, level: currentBattery, reason: isSleeping ? "sleep_recharge" : "hourly")
                }
            }
            
            currentTime = nextTime
        }
        
        // Save final snapshot
        saveSnapshot(timestamp: now, level: currentBattery, reason: "auto_update")
    }
    
    // MARK: - Get Battery Level
    
    /// Get current battery level for today (`nil` until today's battery has started)
    func getCurrentBatteryLevel() -> Double? {
        guard let latest = getLatestBatterySnapshot(),
              latest.timestamp >= Calendar.current.startOfDay(for: Date()) else {
            return nil
        }
        return latest.level
    }
    
    /// Get battery history for the last N days
    func getBatteryHistory(days: Int) -> [BodyBatterySnapshot] {
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        
        let descriptor = FetchDescriptor<BodyBatterySnapshot>(
            predicate: #Predicate { $0.timestamp >= startDate },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    /// Get today's battery snapshots
    func getTodayBattery() -> [BodyBatterySnapshot] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let descriptor = FetchDescriptor<BodyBatterySnapshot>(
            predicate: #Predicate { snapshot in
                snapshot.timestamp >= startOfDay && snapshot.timestamp < endOfDay
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    // MARK: - Private Helpers
    
    /// Your typical calm heart rate while awake: a low percentile of the past week's
    /// awake readings. Falls back to resting HR plus a margin if there isn't enough data.
    private func calmAwakeHeartRate(
        _ samples: [HeartRateSample],
        asleepIntervals: [(start: Date, end: Date)],
        restingHR: Double
    ) -> Double {
        let awake = samples
            .filter { sample in
                !asleepIntervals.contains { $0.start <= sample.date && sample.date <= $0.end }
            }
            .map(\.value)
            .sorted()

        guard awake.count >= 50 else {
            return restingHR + ScoringWeights.lowHRThresholdBPMAboveResting
        }

        let index = Int(Double(awake.count - 1) * ScoringWeights.calmHRPercentile)
        return max(awake[index], restingHR)
    }

    /// Today's starting snapshot, if the day has been started
    private func getTodayStartSnapshot(now: Date) -> BodyBatterySnapshot? {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let reason = "morning_recovery"

        let descriptor = FetchDescriptor<BodyBatterySnapshot>(
            predicate: #Predicate { snapshot in
                snapshot.timestamp >= startOfDay && snapshot.reason == reason
            }
        )

        return try? modelContext.fetch(descriptor).first
    }

    /// Saved recovery score for a given (start-of-day) date
    private func getRecoveryScore(for startOfDay: Date) -> Double? {
        let descriptor = FetchDescriptor<RecoveryScore>(
            predicate: #Predicate { $0.date == startOfDay }
        )

        return try? modelContext.fetch(descriptor).first?.score
    }

    /// End of last night's main sleep: the latest asleep stage that began before noon
    /// and ended today. Returns `nil` if there's no sleep data.
    private func wakeTime(on date: Date) async -> Date? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        guard let noon = calendar.date(byAdding: .hour, value: 12, to: startOfDay),
              let samples = try? await healthKitManager.fetchSleep(days: 1) else {
            return nil
        }

        return samples
            .filter { sample in
                (sample.value == .asleepCore || sample.value == .asleepDeep || sample.value == .asleepREM) &&
                sample.startDate < noon &&
                sample.endDate > startOfDay &&
                sample.endDate <= date
            }
            .map(\.endDate)
            .max()
    }

    private func getLatestBatterySnapshot() -> BodyBatterySnapshot? {
        let descriptor = FetchDescriptor<BodyBatterySnapshot>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        
        return try? modelContext.fetch(descriptor).first
    }
    
    private func saveSnapshot(timestamp: Date, level: Double, reason: String) {
        let snapshot = BodyBatterySnapshot(
            timestamp: timestamp,
            level: level,
            reason: reason
        )
        
        modelContext.insert(snapshot)
        try? modelContext.save()
    }
}
