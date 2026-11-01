//
//  MainDashboardView.swift
//  HealthRecovery
//
//  Full dashboard with recovery score, body battery, and 7-day trend
//

import SwiftUI
import SwiftData
import Charts

struct MainDashboardView: View {
    
    @Environment(\.modelContext) private var modelContext
    
    @State private var healthKitManager = HealthKitManager()
    @State private var isInitializing = false
    @State private var hasAuthorized = false
    @State private var errorMessage: String?
    
    @State private var currentRecoveryScore: Double?
    @State private var currentBatteryLevel: Double?
    @State private var weeklyScores: [RecoveryScore] = []
    @State private var isRefreshing = false
    @State private var lastRefreshed: Date?

    // Last night's values for the summary tiles
    @State private var lastNightSleepHours: Double?
    @State private var lastNightHRV: Double?
    @State private var recentWorkouts: [WorkoutSample] = []
    @State private var sleepHistory: [Double?] = []
    @State private var hrvHistory: [Double?] = []

    /// The tile currently expanded into a detail card, if any
    @State private var expandedTile: DashboardTile?
    /// How far the open card has been dragged toward dismissal (0–1)
    @State private var cardDismissProgress: CGFloat = 0
    /// Incremented to ask the open card to close (it fades its details out first)
    @State private var closeRequests = 0
    @Namespace private var heroNamespace

    @Query private var baselines: [BaselineData]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    /// Automatic refreshes (on launch and when returning to the app) are skipped if the
    /// last one was this recent. Pulling down always refreshes.
    private let automaticRefreshInterval: TimeInterval = 10 * 60

    /// Sleep and HRV sit side by side normally, but stack at accessibility text sizes.
    private var pairLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: tileSpacing))
            : AnyLayout(HStackLayout(spacing: tileSpacing))
    }

    // Quick, lightly springy open; quick, settled close
    private var openAnimation: Animation { .spring(duration: 0.4, bounce: 0.12) }
    private var closeAnimation: Animation { .spring(duration: 0.32, bounce: 0.04) }

    var body: some View {
        ZStack {
            // No NavigationStack here: it hosts its content in a separate UIKit layer,
            // which stops tiles from morphing into the expanded card (drawn above it)
            ScrollView {
                VStack(spacing: 20) {
                    Text("Baseline")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)

                    if let errorMessage {
                        errorBanner(errorMessage)
                    }

                    if !hasAuthorized {
                        setupCard
                    } else {
                        tileGrid

                        // 7-day trend chart
                        if !weeklyScores.isEmpty {
                            trendChartCard
                        }

                        refreshStatus
                    }
                }
                .padding()
            }
            .background(
                AmbientBackground(
                    level: currentRecoveryScore.map(ScoreLevel.init),
                    isPaused: expandedTile != nil
                )
            )
            .refreshable {
                await refreshData()
            }
            // The page stays put (no scaling) so tiles and the card line up exactly
            // while they morph; it just blurs and dims behind the open card
            .allowsHitTesting(expandedTile == nil)
            .accessibilityHidden(expandedTile != nil)

            if let tile = expandedTile {
                CardBackdrop(dismissProgress: $cardDismissProgress) {
                    closeRequests += 1
                }
                .transition(.opacity)

                ExpandedTileCard(
                    tile: tile,
                    snapshot: snapshot,
                    namespace: heroNamespace,
                    dismissProgress: $cardDismissProgress,
                    closeRequests: closeRequests,
                    onClose: closeTile
                ) {
                    RecoveryDetailView(focus: tile.focus, isEmbedded: true)
                }
                .zIndex(1)
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: expandedTile)
        .task {
            await loadInitialData()
            await refreshData(automatic: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshData(automatic: true) }
            }
        }
    }

    // MARK: - Tile grid

    private var tileGrid: some View {
        GlassEffectContainer(spacing: tileGlassBlendDistance) {
            VStack(spacing: tileSpacing) {
                tile(.recovery)
                tile(.battery)
                pairLayout {
                    tile(.sleep)
                    tile(.hrv)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A grid tile, or an invisible placeholder holding its space while it's expanded.
    private func tile(_ tile: DashboardTile) -> some View {
        let isExpanded = expandedTile == tile
        return DashboardTileButton(
            tile: tile,
            snapshot: snapshot,
            namespace: heroNamespace,
            isHeroSource: !isExpanded
        ) {
            withAnimation(openAnimation) {
                expandedTile = tile
            }
        }
        .opacity(isExpanded ? 0 : 1)
    }

    private func closeTile() {
        withAnimation(closeAnimation) {
            expandedTile = nil
            cardDismissProgress = 0
        }
    }

    private var snapshot: DashboardSnapshot {
        DashboardSnapshot(
            recovery: currentRecoveryScore,
            recoveryInsight: recoveryInsight,
            battery: currentBatteryLevel,
            sleepHours: lastNightSleepHours,
            usualSleepHours: baselineMean(MetricType.sleep),
            sleepHistory: sleepHistory,
            hrv: lastNightHRV,
            usualHRV: baselineMean(MetricType.hrv),
            hrvHistory: hrvHistory
        )
    }

    /// One line on what's driving today's score: the metric furthest from usual.
    private var recoveryInsight: String? {
        let today = Calendar.current.startOfDay(for: .now)
        guard let score = weeklyScores.first(where: { $0.date == today }) else { return nil }
        let z = score.metricZScores

        // Positive = better than usual
        let deviations: [(metric: String, goodness: Double)] = [
            ("HRV", z["HRV"] ?? 0),
            ("Resting HR", -(z["Resting HR"] ?? 0)),
            ("Sleep", z["Sleep"] ?? 0)
        ]
        guard let strongest = deviations.max(by: { abs($0.goodness) < abs($1.goodness) }),
              abs(strongest.goodness) >= ScoringWeights.trivialZ else {
            return "Everything is within your normal range."
        }

        switch (strongest.metric, strongest.goodness > 0) {
        case ("HRV", true): return "HRV is above your usual, a good sign."
        case ("HRV", false): return "HRV is below your usual. Consider an easier day."
        case ("Resting HR", true): return "Resting heart rate is lower than usual."
        case ("Resting HR", false): return "Resting heart rate is elevated."
        case ("Sleep", true): return "You slept more than usual."
        default: return "You slept less than usual."
        }
    }
    
    // MARK: - Subviews
    
    private var setupCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red.gradient)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to Baseline")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Allow access to your Health data so the app can learn your baseline and score your daily recovery.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await initializeApp() }
            } label: {
                Group {
                    if isInitializing {
                        ProgressView()
                    } else {
                        Text("Get Started")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isInitializing)
        }
        .padding(28)
        .cardBackground()
    }

    private func baselineMean(_ metricType: String) -> Double? {
        baselines.first { $0.metricType == metricType && $0.sampleCount > 0 }?.mean
    }

    private var weeklyAverage: Int {
        guard !weeklyScores.isEmpty else { return 0 }
        return Int(weeklyScores.map(\.score).reduce(0, +) / Double(weeklyScores.count))
    }

    private var trendChartCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 Days")
                    .font(.title3.bold())
                Spacer()
                Text("Avg \(weeklyAverage)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(weeklyScores) { score in
                AreaMark(
                    x: .value("Date", score.date, unit: .day),
                    y: .value("Score", score.score)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue.opacity(0.3), .blue.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Date", score.date, unit: .day),
                    y: .value("Score", score.score)
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", score.date, unit: .day),
                    y: .value("Score", score.score)
                )
                .foregroundStyle(.blue)
                .symbolSize(50)
                }

                // Workout days along the bottom; their effect shows in the next
                // morning's recovery (through overnight HRV and resting HR)
                ForEach(workoutDays, id: \.date) { day in
                    PointMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Score", 8)
                    )
                    .symbol {
                        Image(systemName: day.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Workout, \(day.minutes) minutes")
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
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .font(.caption)
                }
            }
            .frame(height: 200)
            .accessibilityLabel("Recovery score over the last 7 days")

            if !workoutDays.isEmpty {
                Label("Workout days are marked along the bottom. Their effect shows up in the next morning's recovery.", systemImage: "figure.run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .cardBackground()
    }

    /// "Updated 7:42 PM · Pull down to refresh", or a spinner while an automatic
    /// refresh is running (pull-to-refresh shows its own).
    private var refreshStatus: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Updating…")
            } else if let lastRefreshed {
                Text("Updated \(lastRefreshed.formatted(date: .omitted, time: .shortened)) · Pull down to refresh")
            } else {
                Text("Pull down to refresh")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding()
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 16))
    }
    
    // MARK: - Actions
    
    /// Last night's sleep and average overnight HRV, read directly from HealthKit.
    private func loadLastNight() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let sleep = try? await healthKitManager.fetchSleep(days: 8) else { return }

        // The last 7 nights, oldest first
        let nights = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let nightlySleep = sleep.nightlySleepHours()
        sleepHistory = nights.map { nightlySleep[$0] }
        lastNightSleepHours = nightlySleep[today]

        if let hrv = try? await healthKitManager.fetchHRV(days: 8) {
            let overnight = sleep.overnightHRVByNight(hrv)
            hrvHistory = nights.map { overnight[$0] }
            // Fall back to the latest reading if the watch wasn't worn overnight
            lastNightHRV = overnight[today] ?? hrv.first?.value
        }

        // Workouts for the 7-day chart (one extra day so the first day is complete)
        recentWorkouts = (try? await healthKitManager.fetchWorkouts(days: 8)) ?? []
    }

    /// One marker per day with workouts: the longest workout's icon and total minutes.
    private var workoutDays: [(date: Date, symbol: String, minutes: Int)] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: recentWorkouts) { calendar.startOfDay(for: $0.startDate) }
        // Only days the chart covers, so older workouts don't stretch the axis
        let firstDay = weeklyScores.map(\.date).min() ?? .distantPast
        return byDay.filter { $0.key >= firstDay }.compactMap { day, workouts in
            guard let longest = workouts.max(by: { $0.duration < $1.duration }) else { return nil }
            let minutes = Int((workouts.reduce(0) { $0 + $1.duration } / 60).rounded())
            return (day, longest.symbolName, minutes)
        }
        .sorted { $0.date < $1.date }
    }

    private func loadInitialData() async {
        // Check if already authorized
        let recoveryScorer = RecoveryScorer(
            healthKitManager: healthKitManager,
            modelContainer: modelContext.container
        )
        
        // Try to load existing data
        weeklyScores = await recoveryScorer.getRecoveryScores(lastDays: 7)
        
        if let todayScore = await recoveryScorer.getTodayScore() {
            currentRecoveryScore = todayScore.score
            hasAuthorized = true
        }
        
        // Load battery
        let batteryEngine = BodyBatteryEngine(
            healthKitManager: healthKitManager,
            modelContainer: modelContext.container
        )
        
        currentBatteryLevel = await batteryEngine.getCurrentBatteryLevel()
        
        // If we have data, we're authorized
        if !weeklyScores.isEmpty {
            hasAuthorized = true
        }

        if hasAuthorized {
            await loadLastNight()
        }
    }
    
    private func initializeApp() async {
        isInitializing = true
        errorMessage = nil
        
        do {
            // 1. Request authorization
            try await healthKitManager.requestAuthorization()
            
            // 2. Build baselines
            let baselineBuilder = BaselineBuilder(
                healthKitManager: healthKitManager,
                modelContainer: modelContext.container
            )
            try await baselineBuilder.refreshBaselinesIfNeeded(force: true)
            
            // 3. Compute initial recovery score
            await computeTodayRecovery()
            
            hasAuthorized = true
            lastRefreshed = Date()
            
        } catch {
            errorMessage = "Setup failed: \(error.localizedDescription)"
        }
        
        isInitializing = false
    }
    
    /// Rebuilds baselines (once a day), recomputes today's score, and updates the battery.
    /// - Parameter automatic: `true` for launch/foreground refreshes, which are skipped if
    ///   the last refresh was recent.
    private func refreshData(automatic: Bool = false) async {
        guard hasAuthorized, !isRefreshing, !isInitializing else { return }
        if automatic, let lastRefreshed,
           Date().timeIntervalSince(lastRefreshed) < automaticRefreshInterval {
            return
        }

        isRefreshing = true
        errorMessage = nil
        
        do {
            let baselineBuilder = BaselineBuilder(
                healthKitManager: healthKitManager,
                modelContainer: modelContext.container
            )
            try await baselineBuilder.refreshBaselinesIfNeeded()
            
            // Recompute today's score (this also updates the battery)
            await computeTodayRecovery()
            lastRefreshed = Date()
            
        } catch {
            errorMessage = "Refresh failed: \(error.localizedDescription)"
        }
        
        isRefreshing = false
    }
    
    private func computeTodayRecovery() async {
        do {
            let scorer = RecoveryScorer(
                healthKitManager: healthKitManager,
                modelContainer: modelContext.container
            )
            
            let result = try await scorer.computeRecoveryScore()
            currentRecoveryScore = result.totalScore
            
            // Start today's battery from this score (no-op if already started today),
            // then apply activity and rest since waking up
            let batteryEngine = BodyBatteryEngine(
                healthKitManager: healthKitManager,
                modelContainer: modelContext.container
            )
            await batteryEngine.initializeDayBattery(startingScore: result.totalScore)
            try? await batteryEngine.updateBattery()
            currentBatteryLevel = await batteryEngine.getCurrentBatteryLevel()
            
            // Reload weekly scores
            weeklyScores = await scorer.getRecoveryScores(lastDays: 7)
            await loadLastNight()
            
        } catch {
            errorMessage = "Score computation failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    MainDashboardView()
        .modelContainer(for: [BaselineData.self, RecoveryScore.self, BodyBatterySnapshot.self])
}
