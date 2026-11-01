//
//  RecoveryRingView.swift
//  HealthRecovery
//
//  Ring visualization for recovery score, plus shared styling used across views
//

import SwiftUI

// MARK: - Shared styling

/// Buckets a 0–100 value into a level so every screen uses the same colors and labels.
enum ScoreLevel {
    case excellent, good, fair, poor

    init(_ value: Double) {
        switch value {
        case 75...: self = .excellent
        case 50..<75: self = .good
        case 25..<50: self = .fair
        default: self = .poor
        }
    }

    /// Used for graphics (rings, dots) only — never for text, so contrast stays readable.
    var color: Color {
        switch self {
        case .excellent: .green
        case .good: .yellow
        case .fair: .orange
        case .poor: .red
        }
    }

    var recoveryLabel: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }

    var batteryLabel: String {
        switch self {
        case .excellent: "High"
        case .good: "Medium"
        case .fair: "Low"
        case .poor: "Very Low"
        }
    }
}

extension EnvironmentValues {
    /// `true` inside a view that already sits on Liquid Glass (e.g. an expanded dashboard
    /// card), where cards use a subtle fill instead of stacking glass on glass.
    @Entry var isOnGlass: Bool = false
}

extension View {
    /// Liquid Glass card background, or a subtle translucent fill when already on glass.
    func cardBackground(cornerRadius: CGFloat = 24) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

private struct CardBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.isOnGlass) private var isOnGlass

    func body(content: Content) -> some View {
        if isOnGlass {
            content
                .background(.fill.quaternary, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// A colored dot followed by a label in primary text color.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

/// Circular progress ring that scales to the space it is given.
struct RingGauge<Center: View>: View {
    let progress: Double
    let color: Color
    @ViewBuilder let center: Center

    private let lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)

            center
                .padding(lineWidth + 4)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 160)
    }
}

/// Large rounded number shown inside a ring; scales with Dynamic Type and shrinks to fit.
struct RingValueText: View {
    let value: Double?

    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 44

    var body: some View {
        Text(value.map { "\(Int($0))" } ?? "--")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }
}

// MARK: - Recovery ring

struct RecoveryRingView: View {

    /// `nil` means no score has been computed yet.
    let score: Double?

    private var level: ScoreLevel { ScoreLevel(score ?? 0) }

    var body: some View {
        VStack(spacing: 14) {
            Label("Recovery", systemImage: "heart.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            RingGauge(progress: (score ?? 0) / 100, color: level.color) {
                RingValueText(value: score)
            }

            if score != nil {
                StatusBadge(text: level.recoveryLabel, color: level.color)
            } else {
                Text("No data yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery score")
        .accessibilityValue(score.map { "\(Int($0)) out of 100, \(level.recoveryLabel)" } ?? "No data yet")
    }
}

#Preview {
    VStack {
        RecoveryRingView(score: 85)
        RecoveryRingView(score: 62)
        RecoveryRingView(score: nil)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
