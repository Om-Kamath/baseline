//
//  BodyBatterySnapshot.swift
//  HealthRecovery
//
//  SwiftData time-series model for body battery level
//

import Foundation
import SwiftData

@Model
final class BodyBatterySnapshot {
    var timestamp: Date
    var level: Double // 0-100
    var reason: String? // "sleep_recharge", "activity_drain", "rest_recharge", etc.
    
    init(timestamp: Date, level: Double, reason: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.reason = reason
    }
}
