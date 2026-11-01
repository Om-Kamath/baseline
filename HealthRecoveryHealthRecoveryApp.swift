//
//  HealthRecoveryApp.swift
//  HealthRecovery
//
//  Created on October 27, 2026.
//

import SwiftUI
import SwiftData

@main
struct HealthRecoveryApp: App {
    
    // SwiftData container for persistence
    let modelContainer: ModelContainer
    
    init() {
        do {
            let schema = Schema([
                BaselineData.self,
                RecoveryScore.self,
                BodyBatterySnapshot.self
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
        
        // Register background tasks
        let bgManager = BackgroundUpdateManager(modelContainer: modelContainer)
        Task {
            await bgManager.registerBackgroundTasks()
            await bgManager.scheduleNextUpdate()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            MainDashboardView()
        }
        .modelContainer(modelContainer)
    }
}
