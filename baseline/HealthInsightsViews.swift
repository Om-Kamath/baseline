//
//  HealthInsightsViews.swift
//  Baseline
//
//  Detail sections shown inside the expanded Sleep, HRV, Body Charge, and Recovery
//  cards.
//

import SwiftUI
import Charts

// MARK: - Building blocks

/// A titled card holding one group of insights.
struct InsightSection<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            .font(.headline)

            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// A small labeled value.
struct InsightStat: View {
    let title: String
    let value: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// Two-column grid of stats. Tiles in a row share the same height, a leftover tile
/// spans the full width, and it becomes one column at accessibility text sizes.
struct InsightGrid<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group(subviews: content) { subviews in
            let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
            let rows = stride(from: 0, to: subviews.count, by: columns).map {
                Array(subviews[$0..<min($0 + columns, subviews.count)])
            }

            VStack(spacing: 10) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(rows[index]) { tile in
                            tile
                        }
                    }
                    // Lets every tile in the row stretch to the tallest one
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A plain-language note with an icon.
struct InsightNote: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Formatting

/// "7h 05m" or "42m"
func durationText(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
}

private func timeText(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// Time of day for an offset from midnight (negative = the evening before).
private func timeText(offsetFromMidnight offset: TimeInterval) -> String {
    timeText(Calendar.current.startOfDay(for: .now).addingTimeInterval(offset))
}

private func consistencyLabel(_ variability: TimeInterval) -> String {
    switch variability / 60 {
    case ..<30: "Very consistent"
    case ..<60: "Fairly consistent"
    default: "Irregular"
    }
}

extension SleepStageKind {
    var color: Color {
        switch self {
        case .awake: .orange
        case .rem: .cyan
        case .core: .blue
        case .deep: .indigo
        }
    }
}

// MARK: - Sleep

struct SleepInsightsSection: View {
    let insights: SleepInsights
    let usualSleepHours: Double?
    /// Your usual sleeping wrist temperature, for showing last night as a difference
    var usualWristTemperature: Double? = nil

    var body: some View {
        VStack(spacing: 16) {
            if insights.bedtime != nil {
                lastNight
            }
            if !insights.nights.isEmpty {
                lastSevenNights
            }
            if hasVitals {
                overnightVitals
            }
        }
    }

    // Last night: hypnogram, stage split, and quality
    private var lastNight: some View {
        InsightSection(title: "Last Night", systemImage: "moon.stars.fill", tint: .indigo) {
            if let bedtime = insights.bedtime, let wake = insights.wakeTime {
                Text("\(timeText(bedtime)) – \(timeText(wake))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !insights.hypnogram.isEmpty {
                Chart(insights.hypnogram) { segment in
                    RectangleMark(
                        xStart: .value("Start", segment.start),
                        xEnd: .value("End", segment.end),
                        y: .value("Stage", segment.stage.rawValue)
                    )
                    .foregroundStyle(segment.stage.color)
                    .cornerRadius(2)
                }
                .chartYScale(domain: SleepStageKind.allCases.map(\.rawValue))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Sleep stages through the night")
            }

            stageBreakdown

            InsightGrid {
                InsightStat(title: "Asleep", value: durationText(insights.asleep))
                if let efficiency = insights.efficiency {
                    InsightStat(
                        title: "Efficiency",
                        value: "\(Int((efficiency * 100).rounded()))%",
                        caption: "Time asleep while in bed"
                    )
                }
                InsightStat(
                    title: "Awake",
                    value: durationText(insights.awake),
                    caption: insights.awakenings == 1 ? "1 time" : "\(insights.awakenings) times"
                )
            }
        }
    }

    private var stageBreakdown: some View {
        let stages: [(SleepStageKind, TimeInterval)] = [
            (.deep, insights.deep), (.core, insights.core), (.rem, insights.rem), (.awake, insights.awake)
        ]
        let total = max(1, stages.reduce(0) { $0 + $1.1 })

        return VStack(alignment: .leading, spacing: 10) {
            // Proportional bar
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(stages, id: \.0) { stage, duration in
                        if duration > 0 {
                            Rectangle()
                                .fill(stage.color)
                                .frame(width: max(2, (geometry.size.width - 6) * duration / total))
                        }
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            HStack(alignment: .top) {
                ForEach(stages, id: \.0) { stage, duration in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(stage.color).frame(width: 8, height: 8)
                            Text(stage.rawValue)
                                .font(.caption.weight(.semibold))
                        }
                        Text(durationText(duration))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text("\(Int((duration / total * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // Last 7 nights: stage bars against your usual, plus timing consistency
    private var lastSevenNights: some View {
        InsightSection(title: "Last 7 Nights", systemImage: "calendar", tint: .indigo) {
            Chart {
                ForEach(insights.nights) { night in
                    let hasStages = night.deep + night.core + night.rem > 0
                    if hasStages {
                        BarMark(x: .value("Night", night.night, unit: .day), y: .value("Hours", night.deep / 3600))
                            .foregroundStyle(by: .value("Stage", "Deep"))
                        BarMark(x: .value("Night", night.night, unit: .day), y: .value("Hours", night.core / 3600))
                            .foregroundStyle(by: .value("Stage", "Core"))
                        BarMark(x: .value("Night", night.night, unit: .day), y: .value("Hours", night.rem / 3600))
                            .foregroundStyle(by: .value("Stage", "REM"))
                    } else {
                        BarMark(x: .value("Night", night.night, unit: .day), y: .value("Hours", night.asleep / 3600))
                            .foregroundStyle(by: .value("Stage", "Asleep"))
                    }
                }

                if let usualSleepHours {
                    RuleMark(y: .value("Usual", usualSleepHours))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Usual")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartForegroundStyleScale([
                "Deep": SleepStageKind.deep.color,
                "Core": SleepStageKind.core.color,
                "REM": SleepStageKind.rem.color,
                "Asleep": Color.indigo
            ])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hours = value.as(Double.self) { Text("\(Int(hours))h") }
                    }
                }
            }
            .frame(height: 170)
            .accessibilityLabel("Sleep by stage over the last 7 nights")

            InsightGrid {
                if let bedtime = insights.usualBedtimeOffset, let variability = insights.bedtimeVariability {
                    InsightStat(
                        title: "Usual bedtime",
                        value: timeText(offsetFromMidnight: bedtime),
                        caption: "\(consistencyLabel(variability)), ±\(Int((variability / 60).rounded())) min"
                    )
                }
                if let wake = insights.usualWakeOffset, let variability = insights.wakeVariability {
                    InsightStat(
                        title: "Usual wake time",
                        value: timeText(offsetFromMidnight: wake),
                        caption: "\(consistencyLabel(variability)), ±\(Int((variability / 60).rounded())) min"
                    )
                }
                if let debt = insights.sleepDebt {
                    InsightStat(
                        title: "Sleep debt",
                        value: debt < 60 ? "None" : durationText(debt),
                        caption: "Shortfall vs. your usual, last 7 nights"
                    )
                }
            }

            if let variability = insights.bedtimeVariability, variability / 60 >= 60 {
                InsightNote(
                    text: "Your bedtime shifts by more than an hour from night to night. A steadier schedule usually makes sleep more restorative.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
    }

    // Overnight vitals
    private var hasVitals: Bool {
        insights.averageSleepingHR != nil || insights.respiratoryRate != nil
            || insights.bloodOxygenAverage != nil || insights.wristTemperature != nil
    }

    private var overnightVitals: some View {
        InsightSection(title: "Overnight Vitals", systemImage: "waveform.path.ecg.rectangle", tint: .pink) {
            InsightGrid {
                if let average = insights.averageSleepingHR {
                    InsightStat(
                        title: "Sleeping heart rate",
                        value: "\(Int(average.rounded())) bpm",
                        caption: insights.lowestSleepingHR.map { "Lowest \(Int($0.rounded())) bpm" }
                    )
                }
                if let respiratory = insights.respiratoryRate {
                    InsightStat(title: "Breathing rate", value: String(format: "%.1f /min", respiratory))
                }
                if let oxygen = insights.bloodOxygenAverage {
                    InsightStat(
                        title: "Blood oxygen",
                        value: "\(Int(oxygen.rounded()))%",
                        caption: insights.bloodOxygenLowest.map { "Lowest \(Int($0.rounded()))%" }
                    )
                }
                if let temperature = insights.wristTemperature {
                    if let usual = usualWristTemperature {
                        InsightStat(
                            title: "Wrist temperature",
                            value: String(format: "%+.2f °C", temperature - usual),
                            caption: String(format: "vs. your usual %.1f °C", usual)
                        )
                    } else {
                        InsightStat(
                            title: "Wrist temperature",
                            value: String(format: "%.2f °C", temperature),
                            caption: "Last night"
                        )
                    }
                }
            }
        }
    }
}

// MARK: - HRV

struct HRVInsightsSection: View {
    let insights: HRVInsights
    /// Today's 7-day trend z-scores, used to describe HRV and resting HR together
    let hrvZ: Double?
    let restingHRZ: Double?

    var body: some View {
        VStack(spacing: 16) {
            if insights.nightly.count >= 3 {
                trend
            }
            details
            if let pattern {
                InsightSection(title: "What It Suggests", systemImage: "sparkles", tint: .pink) {
                    Text(pattern)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Based on your 7-day HRV and resting heart rate trends. General information, not medical advice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var trend: some View {
        InsightSection(title: "30-Night Trend", systemImage: "chart.xyaxis.line", tint: .pink) {
            Chart {
                // Your normal range
                if let low = insights.normalLow, let high = insights.normalHigh,
                   let first = insights.nightly.first?.date, let last = insights.nightly.last?.date {
                    RectangleMark(
                        xStart: .value("Start", first),
                        xEnd: .value("End", last),
                        yStart: .value("Low", low),
                        yEnd: .value("High", high)
                    )
                    .foregroundStyle(.green.opacity(0.15))
                }

                ForEach(insights.nightly) { night in
                    PointMark(x: .value("Night", night.date), y: .value("HRV", night.value))
                        .foregroundStyle(.pink.opacity(0.45))
                        .symbolSize(18)
                }

                ForEach(insights.rolling) { point in
                    LineMark(x: .value("Night", point.date), y: .value("7-night avg", point.value))
                        .foregroundStyle(.pink)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ms = value.as(Double.self) { Text("\(Int(ms))") }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Overnight HRV over the last 30 nights")

            Text("Dots: each night. Line: 7-night average. Green band: your normal range, where changes are just day-to-day noise.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var details: some View {
        InsightSection(title: "Last Night", systemImage: "moon.fill", tint: .pink) {
            InsightGrid {
                if let lastNight = insights.lastNight {
                    InsightStat(
                        title: "Overnight average",
                        value: "\(Int(lastNight.rounded())) ms",
                        caption: insights.usual.map { "Usual \(Int($0.rounded())) ms" }
                    )
                }
                if let low = insights.lastNightLow, let high = insights.lastNightHigh, insights.readingsLastNight > 1 {
                    InsightStat(
                        title: "Range",
                        value: "\(Int(low.rounded()))–\(Int(high.rounded())) ms",
                        caption: "\(insights.readingsLastNight) readings"
                    )
                }
                if let daytime = insights.daytimeAverage {
                    InsightStat(
                        title: "Daytime",
                        value: "\(Int(daytime.rounded())) ms",
                        caption: "Today while awake; usually lower than overnight"
                    )
                }
                if let variation = insights.variation {
                    InsightStat(
                        title: "Night-to-night variation",
                        value: "\(Int(variation.rounded()))%",
                        caption: variationLabel(variation)
                    )
                }
            }
        }
    }

    private func variationLabel(_ variation: Double) -> String {
        switch variation {
        case ..<10: "Stable"
        case ..<20: "Typical"
        default: "Unsettled; often follows stress, illness, travel, or a change in training"
        }
    }

    /// HRV and resting HR read together, following common readiness-monitoring patterns
    private var pattern: String? {
        guard let hrvZ, let restingHRZ else { return nil }
        let normal = ScoringWeights.trivialZ
        switch (hrvZ, restingHRZ) {
        case let (hrv, rhr) where hrv <= -normal && rhr >= normal:
            return "HRV is down and resting heart rate is up. Together, these often follow hard training, poor sleep, stress, alcohol, or the start of an illness. An easier day may help."
        case let (hrv, _) where hrv <= -normal:
            return "HRV is below your usual while resting heart rate is steady. Your body may still be absorbing recent stress or training."
        case let (hrv, rhr) where hrv >= normal && rhr <= normal:
            return "HRV is above your usual with a steady or lower resting heart rate, a typical sign of good recovery."
        case let (hrv, rhr) where hrv >= normal && rhr >= normal:
            return "HRV is up but so is resting heart rate, a mixed signal. Heat, dehydration, or a recent change in routine can cause this."
        case let (_, rhr) where rhr >= normal:
            return "Resting heart rate is elevated while HRV is in its normal range. Keep an eye on it over the next few days."
        default:
            return "HRV and resting heart rate are both within your normal range."
        }
    }
}

// MARK: - Body Charge

struct ChargeInsightsSection: View {
    let insights: ChargeInsights

    var body: some View {
        VStack(spacing: 16) {
            InsightSection(title: "Today So Far", systemImage: "chart.line.uptrend.xyaxis", tint: .green) {
                InsightGrid {
                    if let peak = insights.peak {
                        InsightStat(title: "Peak", value: "\(Int(peak.value.rounded()))", caption: timeText(peak.date))
                    }
                    if let low = insights.low {
                        InsightStat(title: "Low", value: "\(Int(low.value.rounded()))", caption: timeText(low.date))
                    }
                    InsightStat(title: "Drained", value: "−\(Int(insights.drained.rounded()))", caption: "By activity and stress")
                    InsightStat(title: "Recharged", value: "+\(Int(insights.recharged.rounded()))", caption: "By rest and sleep")
                    if let energy = insights.activeEnergy {
                        InsightStat(title: "Active energy", value: "\(Int(energy.rounded())) kcal")
                    }
                    if let exercise = insights.exerciseMinutes {
                        InsightStat(title: "Exercise", value: "\(Int(exercise.rounded())) min")
                    }
                }

                if let projection = insights.projection {
                    InsightNote(
                        text: "At today's pace, you'll be around \(Int(projection.value.rounded())) by \(timeText(projection.date)), your usual bedtime.",
                        systemImage: "moon.zzz"
                    )
                }
            }

            if !insights.zoneMinutes.isEmpty {
                zones
            }
        }
    }

    private var zones: some View {
        let total = max(1, insights.zoneMinutes.values.reduce(0, +))

        return InsightSection(title: "Heart Rate Zones", systemImage: "heart.circle", tint: .red) {
            VStack(spacing: 10) {
                ForEach(HeartZone.allCases, id: \.self) { zone in
                    let minutes = insights.zoneMinutes[zone] ?? 0
                    HStack(spacing: 10) {
                        Text(zone.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 80, alignment: .leading)

                        GeometryReader { geometry in
                            Capsule()
                                .fill(zoneColor(zone).gradient)
                                .frame(width: max(4, geometry.size.width * minutes / total))
                        }
                        .frame(height: 10)

                        Text(durationText(minutes * 60))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Text("Time awake today, by how far your heart rate was above your calm level: rest under 5 bpm, light up to 20, moderate up to 45, vigorous beyond.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func zoneColor(_ zone: HeartZone) -> Color {
        switch zone {
        case .rest: .teal
        case .light: .green
        case .moderate: .orange
        case .vigorous: .red
        }
    }
}

// MARK: - Recovery

struct RecoveryInsightsSection: View {
    let score: Double
    /// Daily scores for the last 30 days, oldest first
    let history: [DatedValue]
    let extras: RecoveryExtras?

    var body: some View {
        VStack(spacing: 16) {
            guidance
            if history.count >= 2 {
                historyCard
            }
            if let extras, hasLoad(extras) || extras.vo2Max != nil {
                loadAndFitness(extras)
            }
        }
    }

    private var guidance: some View {
        let level = ScoreLevel(score)
        let (title, text, icon): (String, String, String) = switch level {
        case .excellent:
            ("Primed", "Your body looks well recovered. A good day for a harder workout if you want one.", "figure.run")
        case .good:
            ("Steady", "You're in a normal range. Usual training and activity should be fine.", "figure.walk")
        case .fair:
            ("Take it easier", "Recovery is below your usual. Consider lighter activity and an earlier night.", "figure.cooldown")
        case .poor:
            ("Prioritize rest", "Several signals are well below your usual. Rest, hydration, and sleep will help most today.", "bed.double.fill")
        }

        return InsightSection(title: title, systemImage: icon, tint: level.color) {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text("General guidance, not medical advice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var historyCard: some View {
        let values = history.map(\.value)
        let average = values.reduce(0, +) / Double(values.count)
        let best = history.max { $0.value < $1.value }
        let lowest = history.min { $0.value < $1.value }

        return InsightSection(title: "Last 30 Days", systemImage: "calendar", tint: .blue) {
            Chart {
                ForEach(history) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Recovery", day.value))
                        .foregroundStyle(ScoreLevel(day.value).color.gradient)
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100])
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Recovery score over the last 30 days")

            InsightGrid {
                InsightStat(title: "Average", value: "\(Int(average.rounded()))", caption: "\(history.count) days")
                if let best {
                    InsightStat(
                        title: "Best",
                        value: "\(Int(best.value.rounded()))",
                        caption: best.date.formatted(.dateTime.month(.abbreviated).day())
                    )
                }
                if let lowest {
                    InsightStat(
                        title: "Lowest",
                        value: "\(Int(lowest.value.rounded()))",
                        caption: lowest.date.formatted(.dateTime.month(.abbreviated).day())
                    )
                }
            }
        }
    }

    private func hasLoad(_ extras: RecoveryExtras) -> Bool {
        extras.yesterdayEnergy != nil || extras.yesterdayExercise != nil
    }

    private func loadAndFitness(_ extras: RecoveryExtras) -> some View {
        InsightSection(title: "Yesterday & Fitness", systemImage: "flame.fill", tint: .orange) {
            InsightGrid {
                if let energy = extras.yesterdayEnergy {
                    InsightStat(
                        title: "Active energy",
                        value: "\(Int(energy.rounded())) kcal",
                        caption: comparison(energy, usual: extras.usualEnergy)
                    )
                }
                if let exercise = extras.yesterdayExercise {
                    InsightStat(
                        title: "Exercise",
                        value: "\(Int(exercise.rounded())) min",
                        caption: comparison(exercise, usual: extras.usualExercise)
                    )
                }
                if let vo2 = extras.vo2Max {
                    InsightStat(
                        title: "Cardio fitness (VO₂ max)",
                        value: String(format: "%.1f", vo2),
                        caption: extras.vo2MaxChange.map { String(format: "%+.1f over the last few months", $0) }
                            ?? extras.vo2MaxDate.map { "Measured \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                    )
                }
            }

            Text("Yesterday's activity shows up in this morning's recovery through overnight HRV and resting heart rate, not as a direct penalty.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func comparison(_ value: Double, usual: Double?) -> String? {
        guard let usual, usual > 0 else { return nil }
        let percent = Int(((value - usual) / usual * 100).rounded())
        if abs(percent) < 5 { return "About your usual" }
        return "\(percent > 0 ? "+" : "")\(percent)% vs. your usual"
    }
}
