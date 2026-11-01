//
//  GlassDashboard.swift
//  Baseline
//
//  Liquid Glass dashboard tiles that expand into full detail cards, plus the
//  ambient background the glass refracts.
//

import SwiftUI

// MARK: - Tiles

/// The tiles on the dashboard grid. Each one expands into a detail card.
enum DashboardTile: String, Hashable, Sendable, CaseIterable {
    case recovery, battery, sleep, hrv

    var title: String {
        switch self {
        case .recovery: "Recovery"
        case .battery: "Body Charge"
        case .sleep: "Sleep"
        case .hrv: "HRV"
        }
    }

    var systemImage: String {
        switch self {
        case .recovery: "heart.fill"
        case .battery: "bolt.fill"
        case .sleep: "bed.double.fill"
        case .hrv: "waveform.path.ecg"
        }
    }

    var focus: DetailFocus {
        switch self {
        case .recovery: .recovery
        case .battery: .battery
        case .sleep: .sleep
        case .hrv: .hrv
        }
    }
}

/// Everything the tiles display, gathered by the dashboard.
struct DashboardSnapshot {
    var recovery: Double?
    var recoveryInsight: String?
    var battery: Double?
    var sleepHours: Double?
    var usualSleepHours: Double?
    /// Oldest first, one entry per night for the last 7 nights (`nil` = no data)
    var sleepHistory: [Double?] = []
    var hrv: Double?
    var usualHRV: Double?
    var hrvHistory: [Double?] = []

    /// Battery change since the day started (it starts at the recovery score)
    var batteryChange: Double? {
        guard let battery, let recovery else { return nil }
        return battery - recovery
    }
}

/// Identifies the views that fly between a grid tile and its expanded card.
private struct HeroID: Hashable {
    enum Part: Hashable { case card, content }
    let tile: DashboardTile
    let part: Part
}

/// Tiles and their expanded cards share one corner radius so the shape doesn't jump
/// while a tile flies into its card.
let tileCornerRadius: CGFloat = 32
private let expandedCornerRadius: CGFloat = tileCornerRadius

/// Spacing between tiles, and how close glass shapes must get before they blend.
/// The blend distance must stay well below the gap, or tiles flicker between
/// separate shapes and one merged shape as they move.
let tileSpacing: CGFloat = 16
let tileGlassBlendDistance: CGFloat = 4

// MARK: - Grid tile

/// A dashboard tile: glass card with the tile's content. Tapping it expands it.
struct DashboardTileButton: View {
    let tile: DashboardTile
    let snapshot: DashboardSnapshot
    let namespace: Namespace.ID
    /// `false` for the placeholder left in the grid while this tile is expanded
    let isHeroSource: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TileContent(tile: tile, snapshot: snapshot, showsHistory: true)
                .geometryGroup()
                .hero(.content, of: tile, in: namespace, isActive: isHeroSource)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(.rect(cornerRadius: tileCornerRadius))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: tileCornerRadius))
                .hero(.card, of: tile, in: namespace, isActive: isHeroSource)
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows details")
    }

    private var accessibilityLabel: String {
        switch tile {
        case .recovery:
            snapshot.recovery.map { "Recovery, \(Int($0)), \(ScoreLevel($0).recoveryLabel)" } ?? "Recovery, no data yet"
        case .battery:
            snapshot.battery.map { "Body charge, \(Int($0)), \(ScoreLevel($0).batteryLabel)" } ?? "Body charge, no data yet"
        case .sleep:
            snapshot.sleepHours.map { "Sleep, \(sleepDurationText($0))" } ?? "Sleep, no data yet"
        case .hrv:
            snapshot.hrv.map { "HRV, \(Int($0.rounded())) milliseconds" } ?? "HRV, no data yet"
        }
    }
}

/// Gently squeezes tiles while pressed.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private extension View {
    /// Applies a matched geometry effect only while `isActive`, so a placeholder copy
    /// of a tile doesn't compete with the expanded card for the same identity.
    @ViewBuilder
    func hero(_ part: HeroID.Part, of tile: DashboardTile, in namespace: Namespace.ID, isActive: Bool) -> some View {
        if isActive {
            matchedGeometryEffect(id: HeroID(tile: tile, part: part), in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Tile content

/// The content of a tile. The same view becomes the header of the expanded card, so
/// it can fly smoothly from one to the other.
private struct TileContent: View {
    let tile: DashboardTile
    let snapshot: DashboardSnapshot
    let showsHistory: Bool

    var body: some View {
        switch tile {
        case .recovery: recovery
        case .battery: battery
        case .sleep:
            compact(
                value: snapshot.sleepHours.map(sleepDurationText),
                usual: snapshot.usualSleepHours.map { "Usual \(sleepDurationText($0))" },
                history: snapshot.sleepHistory,
                color: .indigo
            )
        case .hrv:
            compact(
                value: snapshot.hrv.map { "\(Int($0.rounded())) ms" },
                usual: snapshot.usualHRV.map { "Usual \(Int($0.rounded())) ms" },
                history: snapshot.hrvHistory,
                color: .pink
            )
        }
    }

    private var titleLabel: some View {
        let color: Color = switch tile {
        case .recovery: snapshot.recovery.map { ScoreLevel($0).color } ?? .secondary
        case .battery: snapshot.battery.map { ScoreLevel($0).color } ?? .secondary
        case .sleep: .indigo
        case .hrv: .pink
        }

        return HStack(spacing: 6) {
            Image(systemName: tile.systemImage)
                .foregroundStyle(color)
            Text(tile.title)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
    }

    // Recovery: ring, status, and a one-line insight
    private var recovery: some View {
        let level = ScoreLevel(snapshot.recovery ?? 0)

        return HStack(alignment: .center, spacing: 20) {
            RingGauge(progress: (snapshot.recovery ?? 0) / 100, color: level.color) {
                RingValueText(value: snapshot.recovery)
            }
            .frame(width: 124)

            VStack(alignment: .leading, spacing: 10) {
                titleLabel

                if snapshot.recovery != nil {
                    StatusBadge(text: level.recoveryLabel, color: level.color)
                }

                Text(snapshot.recoveryInsight ?? "Pull down to compute today's score.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Battery: big value and a glowing gauge
    private var battery: some View {
        let level = ScoreLevel(snapshot.battery ?? 0)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                titleLabel
                Spacer(minLength: 8)
                if let change = snapshot.batteryChange {
                    Text("\(String(format: "%+d", Int(change.rounded()))) since waking")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.battery.map { "\(Int($0))" } ?? "--")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(snapshot.battery == nil ? "No data yet" : level.batteryLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            BatteryGauge(level: snapshot.battery)
        }
    }

    // Sleep / HRV: value, usual, and a 7-night mini chart
    private func compact(value: String?, usual: String?, history: [Double?], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            titleLabel

            Text(value ?? "--")
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(usual ?? "Last night")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if showsHistory {
                Spacer(minLength: 8)
                MiniBars(values: history, color: color)
                    .frame(height: 34)
            }
        }
    }
}

// MARK: - Expanded card

/// A tile expanded into a full-height glass card: the tile's content as a pinned
/// header, with details flowing in below. Swipe the header down to collapse it.
struct ExpandedTileCard<Detail: View>: View {
    let tile: DashboardTile
    let snapshot: DashboardSnapshot
    let namespace: Namespace.ID
    /// 0 at rest, 1 when dragged far down; lets the dashboard come forward as you drag
    @Binding var dismissProgress: CGFloat
    /// Changes when something outside the card (e.g. tapping the dimmed background)
    /// asks it to close
    var closeRequests: Int = 0
    let onClose: () -> Void
    @ViewBuilder let detail: Detail

    /// Resets with a spring when the finger lifts or the gesture is cancelled
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.4, dampingFraction: 0.8)))
    private var dragOffset: CGFloat = 0
    @State private var showsDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 at rest, 1 when dragged far enough to feel fully "pulled"
    private var dragProgress: CGFloat { min(max(dragOffset / 320, 0), 1) }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                // Details are only built once the card has finished growing, so their
                // layout and data loading don't compete with the expand animation
                if showsDetail {
                    detail
                        .environment(\.isOnGlass, true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                        .transition(.opacity.combined(with: .offset(y: 16)))
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .clipShape(.rect(cornerRadius: expandedCornerRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: expandedCornerRadius))
        .hero(.card, of: tile, in: namespace, isActive: true)
        // Interactive collapse: the card shrinks and follows the finger
        .scaleEffect(1 - dragProgress * 0.14, anchor: .top)
        .offset(y: dragOffset * 0.55)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: dragProgress) { _, progress in
            dismissProgress = progress
        }
        .onChange(of: closeRequests) {
            close()
        }
        .task {
            // Wait for the expand animation to (mostly) finish before adding details
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 280))
            withAnimation(.easeOut(duration: 0.22)) {
                showsDetail = true
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
    }

    /// Fades the details out quickly, then collapses the card back into its tile, so
    /// only the header shrinks into the tile.
    private func close() {
        withAnimation(.easeOut(duration: 0.12)) {
            showsDetail = false
        }
        onClose()
    }

    private var header: some View {
        VStack(spacing: 14) {
            // Grabber hints that the card can be swiped away
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 10)
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 12) {
                TileContent(tile: tile, snapshot: snapshot, showsHistory: false)
                    .geometryGroup()
                    .hero(.content, of: tile, in: namespace, isActive: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($dragOffset) { value, state, _ in
                    // Follow downward drags; ignore upward ones
                    state = max(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                        close()
                    }
                }
        )
    }
}

// MARK: - Backdrop

/// Frosted, dimmed layer behind an open card. A material that fades in is far cheaper
/// than animating a blur over the dashboard. It reads the drag progress itself, so
/// dragging the card only redraws this layer, not the whole dashboard.
struct CardBackdrop: View {
    @Binding var dismissProgress: CGFloat
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.2)
        }
        .opacity(1 - dismissProgress)
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .accessibilityHidden(true)
    }
}

// MARK: - Gauges

/// Horizontal battery gauge: a red-to-green gradient revealed up to the level, with a
/// soft glow in the level's color.
struct BatteryGauge: View {
    let level: Double?

    var body: some View {
        let progress = min(max((level ?? 0) / 100, 0), 1)
        let color = ScoreLevel(level ?? 0).color

        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.fill.tertiary)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.red, .orange, .yellow, .green],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width)
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: max(geometry.size.height, geometry.size.width * progress))
                    }
                    .opacity(level == nil ? 0 : 1)
                    .shadow(color: color.opacity(0.55), radius: 8)
            }
        }
        .frame(height: 14)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
        .accessibilityHidden(true)
    }
}

/// Tiny bar chart of recent nights; the latest night is highlighted.
struct MiniBars: View {
    let values: [Double?]
    let color: Color

    var body: some View {
        let maxValue = values.compactMap { $0 }.max() ?? 1

        HStack(alignment: .bottom, spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                let isLatest = index == values.count - 1
                Capsule()
                    .fill(values[index] == nil ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(color.opacity(isLatest ? 1 : 0.35)))
                    .frame(maxWidth: .infinity)
                    .frame(height: values[index].map { max(4, 34 * $0 / maxValue) } ?? 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Ambient background

/// A slowly drifting mesh gradient tinted by today's recovery level. Gives the
/// Liquid Glass something colorful to refract.
struct AmbientBackground: View {
    let level: ScoreLevel?
    /// Stops the drift (e.g. while a card covers the dashboard)
    var isPaused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || isPaused)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(at: time), colors: colors)
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: level)
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        let accent = level?.color ?? .blue
        return [
            accent.opacity(0.50), .teal.opacity(0.30), .indigo.opacity(0.40),
            .blue.opacity(0.25), accent.opacity(0.30), .purple.opacity(0.28),
            .indigo.opacity(0.38), accent.opacity(0.42), .teal.opacity(0.26)
        ]
    }

    /// Corners stay fixed; the edges and center drift gently over time.
    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double) -> Float {
            Float(sin(time * speed + phase) * 0.08)
        }
        return [
            [0, 0], [0.5 + wave(0.21, 0), 0], [1, 0],
            [0, 0.5 + wave(0.17, 1)], [0.5 + wave(0.13, 2), 0.5 + wave(0.19, 3)], [1, 0.5 + wave(0.23, 4)],
            [0, 1], [0.5 + wave(0.15, 5), 1], [1, 1]
        ]
    }
}

// MARK: - Helpers

func sleepDurationText(_ hours: Double) -> String {
    let minutes = max(0, Int((hours * 60).rounded()))
    return "\(minutes / 60)h \(minutes % 60)m"
}

// MARK: - Preview

#Preview("Glass tiles") {
    @Previewable @Namespace var namespace
    @Previewable @State var expanded: DashboardTile?

    let snapshot = DashboardSnapshot(
        recovery: 72,
        recoveryInsight: "HRV is above your usual, a good sign.",
        battery: 58,
        sleepHours: 6.4,
        usualSleepHours: 7.2,
        sleepHistory: [7.1, 6.8, 7.5, nil, 7.9, 7.0, 6.4],
        hrv: 61,
        usualHRV: 54,
        hrvHistory: [52, 55, 49, 58, 57, nil, 61]
    )

    ZStack {
        ScrollView {
            GlassEffectContainer(spacing: tileGlassBlendDistance) {
                VStack(spacing: tileSpacing) {
                    ForEach([DashboardTile.recovery, .battery], id: \.self) { tile in
                        DashboardTileButton(tile: tile, snapshot: snapshot, namespace: namespace, isHeroSource: expanded != tile) {
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { expanded = tile }
                        }
                        .opacity(expanded == tile ? 0 : 1)
                    }
                    HStack(spacing: tileSpacing) {
                        ForEach([DashboardTile.sleep, .hrv], id: \.self) { tile in
                            DashboardTileButton(tile: tile, snapshot: snapshot, namespace: namespace, isHeroSource: expanded != tile) {
                                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { expanded = tile }
                            }
                            .opacity(expanded == tile ? 0 : 1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .background(AmbientBackground(level: .good))
        .scaleEffect(expanded == nil ? 1 : 0.93)
        .blur(radius: expanded == nil ? 0 : 10)

        if let tile = expanded {
            ExpandedTileCard(tile: tile, snapshot: snapshot, namespace: namespace, dismissProgress: .constant(0)) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { expanded = nil }
            } detail: {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<4) { _ in
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.fill.quaternary)
                            .frame(height: 110)
                    }
                }
            }
            .zIndex(1)
            .transition(.asymmetric(insertion: .identity, removal: .opacity))
        }
    }
}
