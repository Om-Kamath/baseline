//
//  BaselineData.swift
//  HealthRecovery
//
//  SwiftData model for 60-day rolling baselines
//

import Foundation
import SwiftData

@Model
final class BaselineData {
    @Attribute(.unique) var metricType: String
    var mean: Double
    var standardDeviation: Double
    var sampleCount: Int
    var lastUpdated: Date
    var samples: [Double] // Rolling window of raw values
    
    init(metricType: String, mean: Double, standardDeviation: Double, sampleCount: Int, lastUpdated: Date, samples: [Double]) {
        self.metricType = metricType
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.sampleCount = sampleCount
        self.lastUpdated = lastUpdated
        self.samples = samples
    }
}
