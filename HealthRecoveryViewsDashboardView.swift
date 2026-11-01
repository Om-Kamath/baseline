//
//  DashboardView.swift
//  HealthRecovery
//
//  Main dashboard - FOR NOW just testing HealthKit authorization and HRV query
//

import SwiftUI

struct DashboardView: View {
    
    @State private var healthKitManager = HealthKitManager()
    @State private var authorizationStatus: String = "Not requested"
    @State private var hrvSamples: [HRVSample] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                // Authorization section
                VStack(spacing: 12) {
                    Text("HealthKit Authorization")
                        .font(.headline)
                    
                    Text(authorizationStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button(action: requestAuthorization) {
                        Label("Request Access", systemImage: "heart.text.square")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
                }
                .padding()
                .background(Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                Divider()
                
                // HRV data section
                VStack(spacing: 12) {
                    HStack {
                        Text("HRV Samples (Last 7 Days)")
                            .font(.headline)
                        
                        Spacer()
                        
                        Button(action: fetchHRVData) {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.medium))
                        }
                        .disabled(isLoading)
                    }
                    
                    if isLoading {
                        ProgressView()
                            .padding()
                    } else if hrvSamples.isEmpty {
                        Text("No HRV data yet. Tap refresh after granting permission.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(hrvSamples.prefix(10)) { sample in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(sample.date, style: .date)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(sample.date, style: .time)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        
                                        Spacer()
                                        
                                        Text("\(Int(sample.value)) ms")
                                            .font(.body.monospacedDigit())
                                            .fontWeight(.semibold)
                                    }
                                    .padding(.vertical, 4)
                                    
                                    if sample.id != hrvSamples.prefix(10).last?.id {
                                        Divider()
                                    }
                                }
                                
                                if hrvSamples.count > 10 {
                                    Text("+ \(hrvSamples.count - 10) more samples")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 8)
                                }
                            }
                            .padding()
                        }
                        .frame(maxHeight: 300)
                        .background(Color(white: 0.97))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
                .background(Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                if let errorMessage {
                    Text("Error: \(errorMessage)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Health Recovery")
            .background(Color(white: 0.92))
        }
    }
    
    // MARK: - Actions
    
    private func requestAuthorization() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                try await healthKitManager.requestAuthorization()
                await MainActor.run {
                    authorizationStatus = "✅ Authorized"
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    authorizationStatus = "❌ Failed"
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
    
    private func fetchHRVData() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let samples = try await healthKitManager.fetchHRV(days: 7)
                await MainActor.run {
                    hrvSamples = samples
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    DashboardView()
}
