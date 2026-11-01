//
//  BatteryRingView.swift
//  HealthRecovery
//
//  Ring visualization for body battery level
//

import SwiftUI

struct BatteryRingView: View {

    /// `nil` means the battery hasn't been initialized yet.
    let level: Double?

    private var scoreLevel: ScoreLevel { ScoreLevel(level ?? 0) }

    var body: some View {
        VStack(spacing: 14) {
            Label("Body Charge", systemImage: "bolt.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            RingGauge(progress: (level ?? 0) / 100, color: scoreLevel.color) {
                RingValueText(value: level)
            }

            if level != nil {
                StatusBadge(text: scoreLevel.batteryLabel, color: scoreLevel.color)
            } else {
                Text("No data yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Body charge")
        .accessibilityValue(level.map { "\(Int($0)) percent, \(scoreLevel.batteryLabel)" } ?? "No data yet")
    }
}

// MARK: - Compact tiles

/// Small card with an icon title, a large value, a secondary detail, and an optional accessory
/// (e.g. a progress bar). Used in the dashboard's right-hand column.
struct MetricTile<Accessory: View>: View {
    let title: String
    let systemImage: String
    let iconColor: Color
    let value: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)

            // Value and detail side by side when they fit, stacked otherwise
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    valueText
                    detailText
                }
                VStack(alignment: .leading, spacing: 2) {
                    valueText
                    detailText
                }
            }

            accessory
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(detail)")
    }

    private var valueText: some View {
        Text(value)
            .font(.title3.weight(.bold))
            .fontDesign(.rounded)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var detailText: some View {
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

extension MetricTile where Accessory == EmptyView {
    init(title: String, systemImage: String, iconColor: Color, value: String, detail: String) {
        self.init(
            title: title,
            systemImage: systemImage,
            iconColor: iconColor,
            value: value,
            detail: detail,
            accessory: { EmptyView() }
        )
    }
}

/// Body battery as a compact tile with a horizontal bar.
struct BatteryBarView: View {

    /// `nil` means the battery hasn't been started today.
    let level: Double?

    private var scoreLevel: ScoreLevel { ScoreLevel(level ?? 0) }

    var body: some View {
        MetricTile(
            title: "Body Charge",
            systemImage: "bolt.fill",
            iconColor: level == nil ? .secondary : scoreLevel.color,
            value: level.map { "\(Int($0))" } ?? "--",
            detail: level == nil ? "No data yet" : scoreLevel.batteryLabel
        ) {
            ProgressView(value: min(max((level ?? 0) / 100, 0), 1))
                .tint(scoreLevel.color)
        }
    }
}

#Preview("Body charge bar") {
    VStack {
        BatteryBarView(level: 72)
        BatteryBarView(level: 30)
        BatteryBarView(level: nil)
    }
    .frame(width: 180)
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview {
    VStack {
        BatteryRingView(level: 92)
        BatteryRingView(level: 58)
        BatteryRingView(level: nil)
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
