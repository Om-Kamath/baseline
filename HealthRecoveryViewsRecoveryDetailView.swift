//
//  RecoveryDetailView.swift
//  HealthRecovery
//
//  Detailed breakdown of recovery score contributions, z-scores, and today's body battery
//

import SwiftUI
import SwiftData
import Charts

/// One measured value that feeds into a metric (most metrics have one; Respiratory & Temp has two).
private struct MetricPart {
    let zKey: String          // Key in RecoveryScore.metricZScores
    let baselineKey: String   // BaselineData.metricType
    let label: String
    let format: @Sendable (Double) -> String
}

/// A scored metric as stored in RecoveryScore.contributions, with its maximum possible points.
private struct MetricInfo {
    let name: String          // Key in RecoveryScore.contributions
    let icon: String
    let maxPoints: Double
    let parts: [MetricPart]
}

/// Ordered by weight so the biggest drivers of the score appear first.
private let metricInfos: [MetricInfo] = [
    MetricInfo(
        name: "HRV",
        icon: "waveform.path.ecg",
        maxPoints: ScoringWeights.hrvWeight * 100,
        parts: [MetricPart(zKey: "HRV", baselineKey: MetricType.hrv, label: "HRV") { "\(Int($0.rounded())) ms" }]
    ),
    MetricInfo(
        name: "Sleep",
        icon: "bed.double.fill",
        maxPoints: ScoringWeights.sleepWeight * 100,
        parts: [MetricPart(zKey: "Sleep", baselineKey: MetricType.sleep, label: "Sleep") { hours in
            let minutes = max(0, Int((hours * 60).rounded()))
            return "\(minutes / 60)h \(minutes % 60)m"
        }]
    ),
    MetricInfo(
        name: "Resting HR",
        icon: "heart.fill",
        maxPoints: ScoringWeights.restingHRWeight * 100,
        parts: [MetricPart(zKey: "Resting HR", baselineKey: MetricType.restingHR, label: "Resting HR") { "\(Int($0.rounded())) bpm" }]
    ),
    MetricInfo(
        name: "Respiratory & Temp",
        icon: "lungs.fill",
        maxPoints: ScoringWeights.respiratoryAndTempWeight * 100,
        parts: [
            MetricPart(zKey: "Respiratory Rate", baselineKey: MetricType.respiratoryRate, label: "Respiratory Rate") {
                String(format: "%.1f br/min", $0)
            },
            MetricPart(zKey: "Wrist Temp", baselineKey: MetricType.wristTemp, label: "Wrist Temperature") {
                String(format: "%+.2f °C", $0)
            }
        ]
    )
]

/// Which part of today's details to show.
enum DetailFocus: Hashable, Sendable {
    /// Everything (standalone), or what drove the score (embedded)
    case recovery
    case battery
    case sleep
    case hrv
}

struct RecoveryDetailView: View {

    /// The section to show; `.recovery` shows everything when not embedded
    let focus: DetailFocus
    /// `true` when shown inside an expanded dashboard card, which provides its own
    /// scroll view, header, and glass background
    let isEmbedded: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var todayScore: RecoveryScore?
    @State private var healthKitManager = HealthKitManager()
    @State private var todayWorkouts: [WorkoutSample] = []
    @State private var showBatteryInfo = false

    @Query private var baselines: [BaselineData]
    @Query private var todaySnapshots: [BodyBatterySnapshot]
    @Query private var latestSnapshots: [BodyBatterySnapshot]

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 72

    init(focus: DetailFocus = .recovery, isEmbedded: Bool = false) {
        self.focus = focus
        self.isEmbedded = isEmbedded

        let startOfDay = Calendar.current.startOfDay(for: .now)
        _todaySnapshots = Query(
            filter: #Predicate<BodyBatterySnapshot> { $0.timestamp >= startOfDay },
            sort: \.timestamp
        )

        // Most recent snapshot overall, used when nothing has been recorded today
        var latest = FetchDescriptor<BodyBatterySnapshot>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        latest.fetchLimit = 1
        _latestSnapshots = Query(latest)
    }

    var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                ScrollView {
                    content
                        .padding()
                }
                .background(AmbientBackground(level: todayScore.map { ScoreLevel($0.score) }))
                .navigationTitle("Recovery Details")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            await loadTodayScore()
            await loadTodayWorkouts()
        }
        .sheet(isPresented: $showBatteryInfo) {
            batteryInfoSheet
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 28) {
            if let score = todayScore {
                switch focus {
                case .recovery:
                    if !isEmbedded {
                        // Overall score and battery (embedded cards show these in their header
                        // and in the battery card)
                        overallScoreCard(score: score)
                        batterySection(recovery: score.score)
                    }

                    // Per-metric contributions
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(
                            "What Drove Your Score",
                            subtitle: "Each metric is compared with your own baseline, not population averages."
                        )
                        metricCards(for: metricInfos, score: score)
                    }

                    // Computed timestamp
                    Text("Computed at \(score.computedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                case .battery:
                    batterySection(recovery: score.score)

                case .sleep:
                    metricCards(for: metricInfos.filter { $0.name == "Sleep" }, score: score)

                case .hrv:
                    metricCards(for: metricInfos.filter { $0.name == "HRV" }, score: score)
                }
            } else {
                ContentUnavailableView(
                    "No Recovery Score",
                    systemImage: "heart.text.square",
                    description: Text("Pull down on the dashboard to compute today's recovery score.")
                )
            }
        }
    }

    private func metricCards(for infos: [MetricInfo], score: RecoveryScore) -> some View {
        ForEach(infos, id: \.name) { info in
            if let contribution = score.contributions[info.name] {
                metricCard(
                    info: info,
                    contribution: contribution,
                    zScores: score.metricZScores,
                    readings: score.metricReadings
                )
            }
        }
    }

    // MARK: - Overall

    private func overallScoreCard(score: RecoveryScore) -> some View {
        let level = ScoreLevel(score.score)

        return VStack(spacing: 8) {
            Text("Today's Recovery")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("\(Int(score.score))")
                .font(.system(size: heroSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            StatusBadge(text: "\(level.recoveryLabel) Recovery", color: level.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's recovery")
        .accessibilityValue("\(Int(score.score)) out of 100, \(level.recoveryLabel)")
    }

    // MARK: - Body Battery

    @ViewBuilder
    private func batterySection(recovery: Double) -> some View {
        let start = todaySnapshots.first
        let current = todaySnapshots.last ?? latestSnapshots.first

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if isEmbedded {
                    Text("Starts at your recovery score, then drains with activity and recharges with rest.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                } else {
                    sectionHeader(
                        "Body Charge Today",
                        subtitle: "Starts at your recovery score, then drains with activity and recharges with rest."
                    )
                }

                Spacer(minLength: 8)

                Button {
                    showBatteryInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                }
                .accessibilityLabel("How body charge changes")
            }

            VStack(alignment: .leading, spacing: 18) {
                if let current {
                    let change = current.level - (start?.level ?? recovery)

                    HStack(spacing: 10) {
                        statTile(
                            "Started",
                            value: start.map { "\(Int($0.level))" } ?? "--",
                            caption: start.map { $0.timestamp.formatted(date: .omitted, time: .shortened) } ?? "Not today"
                        )
                        statTile(
                            "Now",
                            value: "\(Int(current.level))",
                            caption: current.timestamp.formatted(date: .omitted, time: .shortened)
                        )
                        statTile(
                            "Change",
                            value: String(format: "%+d", Int(change.rounded())),
                            caption: "since start"
                        )
                    }

                    if todaySnapshots.count >= 2 {
                        batteryChart
                    }

                    if !todayWorkouts.isEmpty {
                        activitiesList
                    }

                    if let note = batteryNote(start: start, current: current, recovery: recovery) {
                        Label(note, systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Your body charge hasn't been set yet. It starts from your recovery score the first time you compute it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .cardBackground()
        }
    }

    private var batteryChart: some View {
        Chart {
            // Workouts as shaded bands, labeled with their battery cost
            ForEach(todayWorkouts) { workout in
                RectangleMark(
                    xStart: .value("Start", workout.startDate),
                    xEnd: .value("End", workout.endDate),
                    yStart: .value("Charge", 0),
                    yEnd: .value("Charge", 100)
                )
                .foregroundStyle(.orange.opacity(0.18))
                .annotation(position: .overlay, alignment: .top, spacing: 4) {
                    VStack(spacing: 1) {
                        Image(systemName: workout.symbolName)
                        if let impact = batteryImpact(of: workout) {
                            Text(impactText(impact))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                }
            }

            ForEach(todaySnapshots) { snapshot in
                LineMark(
                    x: .value("Time", snapshot.timestamp),
                    y: .value("Charge", snapshot.level)
                )
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine()
                AxisValueLabel()
                    .font(.caption)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
                    .font(.caption)
            }
        }
        .frame(height: 160)
        .accessibilityLabel("Body charge level throughout today")
    }

    /// Explains why battery and recovery look the way they do.
    private func batteryNote(start: BodyBatterySnapshot?, current: BodyBatterySnapshot, recovery: Double) -> String? {
        if start == nil {
            return "No charge updates yet today. Showing the last saved level from \(current.timestamp.formatted(date: .abbreviated, time: .shortened))."
        }
        if todaySnapshots.count == 1 {
            return "Your body charge was just set from today's recovery score and hasn't been updated with activity yet, so the two numbers match. Pull down on the dashboard to apply today's heart rate and sleep."
        }
        if abs(current.level - recovery) < 5 {
            return "Your body charge is within 5 points of your recovery score. Activity drain and rest recharge have roughly balanced out so far today."
        }
        return nil
    }

    private var batteryRulesCard: some View {
        let restTolerance = Int(ScoringWeights.calmHRToleranceBPM)
        let rampMinutes = Int(ScoringWeights.batteryRechargeRampMinutes)
        let stressDrain = (10 * ScoringWeights.batteryDrainRatePerBPMAboveCalm).formatted()
        let walkDrain = Int(30 * ScoringWeights.batteryDrainRatePerBPMAboveCalm)

        return VStack(alignment: .leading, spacing: 18) {
            ruleRow(
                icon: "moon.zzz.fill",
                color: .indigo,
                title: "Sleep",
                detail: "+\(ScoringWeights.batterySleepRechargeRate.formatted()) per hour"
            )
            ruleRow(
                icon: "sofa.fill",
                color: .teal,
                title: "Resting",
                detail: "+\(ScoringWeights.batteryRechargeRateLowHR.formatted()) per hour while heart rate stays within \(restTolerance) bpm of your calm daytime level. Builds up over \(rampMinutes) minutes after activity or stress."
            )
            ruleRow(
                icon: "figure.walk",
                color: .orange,
                title: "Activity & Stress",
                detail: "−\(ScoringWeights.batteryDrainRatePerBPMAboveCalm.formatted()) per hour for every bpm above your calm daytime level. Mild stress (~10 bpm above) drains about \(stressDrain) per hour; a brisk walk (~30 bpm above) about \(walkDrain)."
            )
            ruleRow(
                icon: "figure.run",
                color: .orange,
                title: "Workouts",
                detail: "Shaded on the chart with their charge cost. Like any activity, the drain comes from your heart rate, so a harder effort costs more than an easy one of the same length."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryInfoSheet: some View {
        NavigationStack {
            ScrollView {
                batteryRulesCard
                    .padding()
            }
            .navigationTitle("How It Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showBatteryInfo = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Activities

    private var activitiesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Activities")
                .font(.headline)

            ForEach(todayWorkouts) { workout in
                activityRow(workout)
            }

            if todayWorkouts.contains(where: { batteryImpact(of: $0) == nil }) {
                Text("Pull down on the dashboard to include recent activities in your body charge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activityRow(_ workout: WorkoutSample) -> some View {
        let minutes = Int((workout.duration / 60).rounded())
        let start = workout.startDate.formatted(date: .omitted, time: .shortened)
        let energy = workout.totalEnergyBurned.map { " · \(Int($0.rounded())) kcal" } ?? ""

        return HStack(spacing: 12) {
            Image(systemName: workout.symbolName)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("\(start) · \(minutes) min\(energy)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(batteryImpact(of: workout).map(impactText) ?? "--")
                    .font(.headline)
                    .monospacedDigit()
                Text("charge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Battery change from a workout's start to its end, or `nil` if the battery
    /// hasn't been updated past the end of the workout yet.
    private func batteryImpact(of workout: WorkoutSample) -> Double? {
        guard let start = batteryLevel(at: workout.startDate),
              let end = batteryLevel(at: workout.endDate) else {
            return nil
        }
        return end - start
    }

    /// Battery level at a moment, interpolated between today's snapshots.
    private func batteryLevel(at date: Date) -> Double? {
        guard let first = todaySnapshots.first, let last = todaySnapshots.last,
              date >= first.timestamp, date <= last.timestamp else {
            return nil
        }
        guard let after = todaySnapshots.first(where: { $0.timestamp >= date }) else { return nil }
        guard let before = todaySnapshots.last(where: { $0.timestamp <= date }) else { return after.level }

        let span = after.timestamp.timeIntervalSince(before.timestamp)
        guard span > 0 else { return before.level }
        let fraction = date.timeIntervalSince(before.timestamp) / span
        return before.level + (after.level - before.level) * fraction
    }

    private func impactText(_ impact: Double) -> String {
        String(format: "%+d", Int(impact.rounded()))
    }

    private func ruleRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statTile(_ title: String, value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Metrics

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func metricCard(
        info: MetricInfo,
        contribution: Double,
        zScores: [String: Double],
        readings: [String: MetricReading]
    ) -> some View {
        let fraction = info.maxPoints > 0 ? contribution / info.maxPoints : 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(info.name, systemImage: info.icon)
                    .font(.headline)

                Spacer()

                Text("\(Int(contribution.rounded())) of \(Int(info.maxPoints)) pts")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            // Share of this metric's available points that were earned
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(ScoreLevel(fraction * 100).color)
                .accessibilityHidden(true)

            ForEach(info.parts, id: \.zKey) { part in
                partDetail(
                    part,
                    zScore: zScores[part.zKey] ?? 0,
                    reading: readings[part.zKey],
                    // Scores saved before readings were stored fall back to the baseline
                    isLegacyScore: readings.isEmpty,
                    showLabel: info.parts.count > 1
                )
            }
        }
        .padding()
        .cardBackground()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func partDetail(
        _ part: MetricPart,
        zScore: Double,
        reading: MetricReading?,
        isLegacyScore: Bool,
        showLabel: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showLabel {
                Divider()
                Text(part.label)
                    .font(.subheadline.weight(.semibold))
            }

            if let reading {
                // Exactly what the score was computed from
                HStack(spacing: 10) {
                    valueColumn(reading.valueLabel, part.format(reading.value))
                    valueColumn("Your usual", part.format(reading.usual))
                }

                Text("Typical range \(part.format(reading.rangeLow)) – \(part.format(reading.rangeHigh))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                zScoreSection(part, zScore: zScore)

                if let note = reading.note {
                    Label(note, systemImage: "checkmark.shield")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if isLegacyScore,
                      let baseline = baselines.first(where: { $0.metricType == part.baselineKey }),
                      baseline.standardDeviation > 0 {
                // Reconstruct today's value from the stored z-score and the baseline it was scored against
                let today = baseline.mean + zScore * baseline.standardDeviation
                let low = baseline.mean - baseline.standardDeviation
                let high = baseline.mean + baseline.standardDeviation

                HStack(spacing: 10) {
                    valueColumn("Today", part.format(today))
                    valueColumn("Your usual", part.format(baseline.mean))
                }

                Text("Typical range \(part.format(low)) – \(part.format(high)), from \(baseline.sampleCount) readings")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                zScoreSection(part, zScore: zScore)
            } else {
                Label(
                    part.zKey == "Sleep"
                        ? "Still building your baseline. Sleep is scored against a 7–9 hour target for now."
                        : "Still building your baseline. This metric is scored as neutral for now.",
                    systemImage: "hourglass"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Z-score bar with labels, plus a plain-language interpretation.
    @ViewBuilder
    private func zScoreSection(_ part: MetricPart, zScore: Double) -> some View {
        // Z-score indicator: where today sits relative to your baseline
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                zScoreBar(zScore)

                HStack {
                    Text("Below")
                    Spacer()
                    Text("Normal")
                    Spacer()
                    Text("Above")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }

            Text(zScoreText(zScore))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }

        Text(interpretZScore(zScore, metricName: part.zKey))
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Horizontal track from -3σ to +3σ with a center tick for the baseline and a dot for today.
    private func zScoreBar(_ zScore: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = normalizeZScore(zScore) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(height: 8)

                // Normal zone (changes this small don't move the score)
                Capsule()
                    .fill(Color.green.opacity(0.25))
                    .frame(width: width * (2 * ScoringWeights.trivialZ / 6), height: 8)
                    .offset(x: width * (0.5 - ScoringWeights.trivialZ / 6))

                // Baseline tick
                Rectangle()
                    .fill(Color(.secondaryLabel))
                    .frame(width: 2, height: 16)
                    .offset(x: width / 2 - 1)

                Circle()
                    .fill(zScoreColor(zScore))
                    .overlay(Circle().stroke(.background, lineWidth: 3))
                    .frame(width: 20, height: 20)
                    .offset(x: min(max(x - 10, 0), width - 20))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 20)
    }

    // MARK: - Helpers

    private func loadTodayScore() async {
        let scorer = RecoveryScorer(
            healthKitManager: healthKitManager,
            modelContainer: modelContext.container
        )

        todayScore = await scorer.getTodayScore()
    }

    private func loadTodayWorkouts() async {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let workouts = (try? await healthKitManager.fetchWorkouts(days: 1)) ?? []
        todayWorkouts = workouts
            .filter { $0.startDate >= startOfToday }
            .sorted { $0.startDate < $1.startDate }
    }

    private func normalizeZScore(_ zScore: Double) -> Double {
        // Map z-score to 0...1 range for visualization
        // -3σ = 0, 0σ = 0.5, +3σ = 1
        let clamped = max(-3, min(3, zScore))
        return (clamped + 3) / 6
    }

    private func zScoreColor(_ zScore: Double) -> Color {
        switch abs(zScore) {
        case 0..<0.5: return .green
        case 0.5..<1.5: return .blue
        case 1.5..<2.5: return .orange
        default: return .red
        }
    }

    private func zScoreText(_ zScore: Double) -> String {
        String(format: "%+.1fσ", zScore)
    }

    private func interpretZScore(_ zScore: Double, metricName: String) -> String {
        let absZ = abs(zScore)

        switch metricName {
        case "HRV":
            if zScore > 1.0 {
                return "Much higher than baseline — excellent sign"
            } else if zScore > 0.5 {
                return "Above baseline — good"
            } else if zScore > -0.5 {
                return "Near baseline — normal"
            } else if zScore > -1.5 {
                return "Below baseline — watch for fatigue"
            } else {
                return "Much lower than baseline — consider rest"
            }

        case "Resting HR":
            if zScore < -1.0 {
                return "Much lower than baseline — excellent"
            } else if zScore < -0.5 {
                return "Below baseline — good"
            } else if zScore < 0.5 {
                return "Near baseline — normal"
            } else if zScore < 1.5 {
                return "Elevated — possible stress or fatigue"
            } else {
                return "Significantly elevated — consider rest"
            }

        case "Sleep":
            if zScore > 1.0 {
                return "Much more sleep than usual — great recovery"
            } else if zScore > 0.5 {
                return "Above average sleep — good"
            } else if zScore > -0.5 {
                return "Normal sleep duration"
            } else {
                return "Less sleep than usual — may impact recovery"
            }

        default:
            if absZ < 0.5 {
                return "Within normal range"
            } else if absZ < 1.5 {
                return "Slight deviation from baseline"
            } else {
                return "Significant deviation from baseline"
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecoveryDetailView()
            .modelContainer(for: [BaselineData.self, RecoveryScore.self, BodyBatterySnapshot.self])
    }
}
