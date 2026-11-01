//
//  ScoringWeights.swift
//  HealthRecovery
//
//  Centralized weights for recovery score calculation
//

import Foundation

nonisolated enum ScoringWeights {
    // Recovery score weights (must sum to 1.0)
    static let hrvWeight: Double = 0.40
    static let restingHRWeight: Double = 0.20
    static let sleepWeight: Double = 0.25
    static let respiratoryAndTempWeight: Double = 0.15
    
    // Converting z-scores to points (see `pointsFromZ`)
    static let trivialZ: Double = 0.5 // changes within ±0.5 SD of usual are treated as normal day-to-day noise
    static let pointsPerStandardDeviation: Double = 25 // beyond that, each SD moves a metric 25 of its 100 points

    // Body battery drain/recharge rates
    static let batteryDrainRatePerBPMAboveCalm: Double = 0.5 // per hour, per BPM above calm awake HR
    static let batteryRechargeRateLowHR: Double = 10.0 // per hour during calm, awake rest
    static let batterySleepRechargeRate: Double = 15.0 // per hour during sleep
    static let batteryRechargeRampMinutes: Double = 30.0 // awake recharge reaches full rate this long after effort
    
    // Thresholds
    static let calmHRPercentile: Double = 0.2 // calm awake HR = 20th percentile of the past week's awake readings
    static let calmHRToleranceBPM: Double = 2.0 // HR within 2 BPM of calm awake HR = "rest"
    static let lowHRThresholdBPMAboveResting: Double = 5.0 // fallback: resting HR + 5 BPM when there's too little HR data
    static let optimalSleepHours: Double = 8.0
    static let minimumSleepHours: Double = 5.0
}
