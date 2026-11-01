//
//  BackgroundUpdateManager.swift
//  HealthRecovery
//
//  Manages background updates using BGTaskScheduler
//

import Foundation
import BackgroundTasks
import SwiftData

actor BackgroundUpdateManager {
    
    static let taskIdentifier = "com.healthrecovery.battery-update"
    
    private let modelContainer: ModelContainer
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }
    
    // MARK: - Register Background Tasks
    
    /// Register background task handler (call from app launch)
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            Task {
                await self.handleBatteryUpdate(task: task as! BGProcessingTask)
            }
        }
    }
    
    // MARK: - Schedule Next Update
    
    /// Schedule the next background update (twice daily)
    func scheduleNextUpdate() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        
        // Run twice a day - schedule next run in ~12 hours
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Scheduled next battery update")
        } catch {
            print("❌ Could not schedule battery update: \(error)")
        }
    }
    
    // MARK: - Handle Background Update
    
    private func handleBatteryUpdate(task: BGProcessingTask) async {
        // Schedule next update before we start work
        scheduleNextUpdate()
        
        // Set expiration handler
        task.expirationHandler = {
            print("⏰ Background task expired")
        }
        
        do {
            let healthKitManager = HealthKitManager()
            let bodyBatteryEngine = BodyBatteryEngine(
                healthKitManager: healthKitManager,
                modelContainer: modelContainer
            )
            
            // Update battery based on recent HR data
            try await bodyBatteryEngine.updateBattery()
            
            print("✅ Background battery update completed")
            task.setTaskCompleted(success: true)
            
        } catch {
            print("❌ Background update failed: \(error)")
            task.setTaskCompleted(success: false)
        }
    }
    
    // MARK: - Manual Trigger (for testing)
    
    /// Force an immediate battery update (useful for testing)
    func triggerImmediateUpdate() async throws {
        let healthKitManager = HealthKitManager()
        let bodyBatteryEngine = BodyBatteryEngine(
            healthKitManager: healthKitManager,
            modelContainer: modelContainer
        )
        
        try await bodyBatteryEngine.updateBattery()
    }
}
