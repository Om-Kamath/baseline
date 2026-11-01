//
//  HealthKitManager.swift
//  HealthRecovery
//
//  Actor that handles all HealthKit authorization and queries
//

import Foundation
import HealthKit

actor HealthKitManager {
    
    private let healthStore = HKHealthStore()
    
    // MARK: - Authorization
    
    /// Request read access to all required health data types
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }
        
        let typesToRead: Set<HKObjectType> = [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRate),
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.appleSleepingWristTemperature),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKObjectType.workoutType(),
            HKQuantityType(.vo2Max),
            HKQuantityType(.oxygenSaturation)
        ]
        
        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
    }
    
    /// Check authorization status for a specific type
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        healthStore.authorizationStatus(for: type)
    }
    
    // MARK: - HRV Query
    
    /// Fetch HRV (SDNN) samples for the last N days
    func fetchHRV(days: Int) async throws -> [HRVSample] {
        let type = HKQuantityType(.heartRateVariabilitySDNN)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        // Convert to typed structs
        return samples.map { sample in
            HRVSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            )
        }
    }
    
    // MARK: - Resting Heart Rate Query
    
    /// Fetch resting heart rate samples for the last N days
    func fetchRestingHeartRate(days: Int) async throws -> [RestingHRSample] {
        let type = HKQuantityType(.restingHeartRate)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { sample in
            RestingHRSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            )
        }
    }
    
    // MARK: - Heart Rate Query
    
    /// Fetch heart rate samples for the last N days
    func fetchHeartRate(days: Int) async throws -> [HeartRateSample] {
        let type = HKQuantityType(.heartRate)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { sample in
            HeartRateSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            )
        }
    }
    
    // MARK: - Sleep Query
    
    /// Fetch sleep analysis samples for the last N days
    func fetchSleep(days: Int) async throws -> [SleepSample] {
        let type = HKCategoryType(.sleepAnalysis)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let categorySamples = samples as? [HKCategorySample] ?? []
                continuation.resume(returning: categorySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.compactMap { sample in
            guard let stage = mapSleepStage(sample.value) else { return nil }
            return SleepSample(
                startDate: sample.startDate,
                endDate: sample.endDate,
                value: stage
            )
        }
    }
    
    private func mapSleepStage(_ value: Int) -> SleepSample.SleepStage? {
        switch value {
        case HKCategoryValueSleepAnalysis.inBed.rawValue:
            return .inBed
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return .asleepCore
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return .asleepDeep
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return .asleepREM
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return .awake
        default:
            return nil
        }
    }
    
    // MARK: - Respiratory Rate Query
    
    /// Fetch respiratory rate samples for the last N days
    func fetchRespiratoryRate(days: Int) async throws -> [RespiratoryRateSample] {
        let type = HKQuantityType(.respiratoryRate)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { sample in
            RespiratoryRateSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            )
        }
    }
    
    // MARK: - Wrist Temperature Query
    
    /// Fetch wrist temperature samples for the last N days
    func fetchWristTemperature(days: Int) async throws -> [WristTemperatureSample] {
        let type = HKQuantityType(.appleSleepingWristTemperature)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { sample in
            WristTemperatureSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: HKUnit.degreeCelsius())
            )
        }
    }
    
    // MARK: - Active Energy Query
    
    /// Fetch active energy burned samples for the last N days
    func fetchActiveEnergy(days: Int) async throws -> [ActiveEnergySample] {
        let type = HKQuantityType(.activeEnergyBurned)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { sample in
            ActiveEnergySample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: .kilocalorie())
            )
        }
    }
    
    // MARK: - Exercise Time Query
    
    /// Fetch exercise time samples for the last N days
    func fetchExerciseTime(days: Int) async throws -> [ExerciseTimeSample] {
        let type = HKQuantityType(.appleExerciseTime)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { sample in
            ExerciseTimeSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: .minute())
            )
        }
    }
    
    // MARK: - Workout Query
    
    /// Fetch workouts for the last N days
    func fetchWorkouts(days: Int) async throws -> [WorkoutSample] {
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let workouts = samples as? [HKWorkout] ?? []
                continuation.resume(returning: workouts)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { workout in
            WorkoutSample(
                startDate: workout.startDate,
                endDate: workout.endDate,
                activityType: workout.workoutActivityType.name,
                duration: workout.duration,
                totalEnergyBurned: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            )
        }
    }
    
    // MARK: - VO2 Max Query
    
    /// Fetch VO2 max samples for the last N days
    func fetchVO2Max(days: Int) async throws -> [VO2MaxSample] {
        let type = HKQuantityType(.vo2Max)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        
        return samples.map { sample in
            VO2MaxSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: vo2Unit)
            )
        }
    }
    
    // MARK: - Blood Oxygen Query
    
    /// Fetch blood oxygen saturation samples for the last N days
    func fetchBloodOxygen(days: Int) async throws -> [BloodOxygenSample] {
        let type = HKQuantityType(.oxygenSaturation)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let quantitySamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            
            healthStore.execute(query)
        }
        
        return samples.map { sample in
            BloodOxygenSample(
                date: sample.startDate,
                value: sample.quantity.doubleValue(for: HKUnit.percent()) * 100
            )
        }
    }
}

// MARK: - Errors

enum HealthKitError: LocalizedError {
    case notAvailable
    case authorizationDenied
    
    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device."
        case .authorizationDenied:
            return "HealthKit authorization was denied."
        }
    }
}

// MARK: - Workout Activity Type Extension

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .traditionalStrengthTraining: return "Strength Training"
        case .coreTraining: return "Core Training"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairs: return "Stairs"
        case .kickboxing: return "Kickboxing"
        case .dance: return "Dance"
        default: return "Other"
        }
    }
}
