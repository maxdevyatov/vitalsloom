import Charts
import SwiftUI

struct AnalysisView: View {
    @Environment(MonitorViewModel.self) private var monitor
    @State private var period: AnalysisPeriod = .twelveHours
    @State private var snapshot: AnalysisSnapshot?
    @State private var oxygenTrend: [OxygenTrendPoint] = []
    @State private var trendScrollPosition = Date.now
    @State private var lastUpdated: Date?
    @State private var customStart = Date.now.addingTimeInterval(-43_200)
    @State private var customEnd = Date.now
    @State private var reloadGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ANALYSIS").font(.headline).foregroundStyle(.cyan)
                    if let snapshot {
                        Text("\(snapshot.periodStart.formatted(date: .abbreviated, time: .shortened)) – \(snapshot.periodEnd.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(AnalysisPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 550)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
            }
            .padding(16)
            .background(Color.white.opacity(0.045))

            if period == .custom {
                HStack(spacing: 22) {
                    Label("EXACT PERIOD", systemImage: "calendar.badge.clock")
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                    DatePicker(
                        "From",
                        selection: $customStart,
                        in: ...customEnd,
                        displayedComponents: [.date, .hourAndMinute])
                    DatePicker(
                        "To",
                        selection: $customEnd,
                        in: customStart...Date.now,
                        displayedComponents: [.date, .hourAndMinute])
                    Spacer()
                    Text(duration(customEnd.timeIntervalSince(customStart)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.025))
                .onChange(of: customStart) { Task { await reload() } }
                .onChange(of: customEnd) { Task { await reload() } }
            }

            if let snapshot, snapshot.sampleCount > 0 {
                ScrollView {
                    oxygenTrendChart
                        .padding(.horizontal, 16).padding(.top, 16)

                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            AnalysisCard(title: "OXYGEN SATURATION", systemImage: "lungs.fill", color: .cyan) {
                                AnalysisMetric(label: "Time below 90%", value: duration(snapshot.timeBelow90), detail: percent(snapshot.below90Fraction))
                                AnalysisMetric(label: "Longest continuous below 90%", value: duration(snapshot.longestBelow90Duration))
                                AnalysisMetric(label: "Time below 88%", value: duration(snapshot.timeBelow88), detail: percent(snapshot.below88Fraction), emphasis: snapshot.timeBelow88 > 0 ? .red : .primary)
                                AnalysisMetric(label: "Longest continuous below 88%", value: duration(snapshot.longestBelow88Duration), emphasis: snapshot.longestBelow88Duration > 0 ? .red : .primary)
                                Divider()
                                AnalysisMetric(label: "Average", value: vital(snapshot.averageOxygen, unit: "%"))
                                AnalysisMetric(label: "Minimum / maximum", value: range(snapshot.minimumOxygen, snapshot.maximumOxygen, unit: "%"))
                            }

                            AnalysisCard(title: "PULSE", systemImage: "heart.fill", color: .green) {
                                AnalysisMetric(label: "Average", value: vital(snapshot.averageHeartRate, unit: " bpm"))
                                AnalysisMetric(label: "Minimum / maximum", value: range(snapshot.minimumHeartRate, snapshot.maximumHeartRate, unit: " bpm"))
                                Divider()
                                AnalysisMetric(label: "Outside configured limits", value: duration(snapshot.pulseOutsideLimitsDuration), detail: "< \(integer(snapshot.lowPulseLimit)) or > \(integer(snapshot.highPulseLimit)) bpm")
                            }
                        }

                        GridRow {
                            AnalysisCard(title: "DATA QUALITY", systemImage: "waveform.path.ecg.rectangle", color: .blue) {
                                AnalysisMetric(label: "Selected period coverage", value: percent(snapshot.coverageFraction), detail: duration(snapshot.monitoredDuration))
                                AnalysisMetric(label: "Valid-data availability", value: percent(snapshot.availabilityFraction), detail: duration(snapshot.availableDuration))
                                AnalysisMetric(label: "Movement affected", value: duration(snapshot.movementDuration))
                                AnalysisMetric(label: "Stale / unavailable", value: duration(snapshot.staleUnavailableDuration))
                                AnalysisMetric(label: "Samples", value: snapshot.sampleCount.formatted())
                            }

                            AnalysisCard(title: "ALARMS", systemImage: "bell.badge.fill", color: .red) {
                                AnalysisMetric(label: "Triggered violations", value: snapshot.alarmCount.formatted())
                                AnalysisMetric(label: "Currently active", value: snapshot.activeAlarmCount.formatted(), emphasis: snapshot.activeAlarmCount > 0 ? .orange : .primary)
                                AnalysisMetric(label: "Completed violation time", value: duration(snapshot.completedAlarmDuration))
                                Divider()
                                Text("Alarm duration is clipped to the selected period. Active violations are finalized when readings stop being fresh or recover.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(16)

                    HStack {
                        Image(systemName: "info.circle")
                        Text("Durations use intervals between contiguous recorded samples. Long gaps are excluded so time when the app was not monitoring is not counted as valid exposure.")
                        Spacer()
                        if let lastUpdated { Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))") }
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 14)
                }
            } else {
                ContentUnavailableView(
                    "No analysis data",
                    systemImage: "chart.bar.xaxis",
                    description: Text("No recorded samples are available for the selected period."))
            }
        }
        .task(id: period) {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let now = Date.now
        let start: Date
        let end: Date
        if period == .custom {
            start = customStart
            end = customEnd
        } else {
            start = now.addingTimeInterval(-period.seconds)
            end = now
        }
        let result = await monitor.analysis(since: start, until: end)
        let trend = await monitor.analysisOxygenTrend(since: start, until: end)
        guard generation == reloadGeneration, !Task.isCancelled else { return }
        snapshot = result
        oxygenTrend = trend
        trendScrollPosition = end
        lastUpdated = now
    }

    private var oxygenTrendChart: some View {
        let values = oxygenTrend.map(\.oxygenSaturation).filter(\.isFinite)
        let minimum = values.min() ?? 88
        let maximum = values.max() ?? 90
        let lower = max(0, floor(min(minimum, 88) - 1))
        let upper = min(100, ceil(max(maximum, 90) + 1))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SpO₂ TREND").font(.system(size: 13, weight: .bold)).foregroundStyle(.cyan)
                Spacer()
                Text("\(trendResolutionLabel) • thresholds 90% and 88%").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(oxygenTrend) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("SpO₂", point.oxygenSaturation),
                        series: .value("Continuous segment", point.segment))
                        .foregroundStyle(.cyan)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if oxygenTrend.count == 1, let point = oxygenTrend.first {
                    PointMark(x: .value("Time", point.timestamp), y: .value("SpO₂", point.oxygenSaturation))
                        .foregroundStyle(.cyan).symbolSize(42)
                }
                RuleMark(y: .value("90% threshold", 90))
                    .foregroundStyle(.orange.opacity(0.95))
                    .lineStyle(.init(lineWidth: 1.5, dash: [6, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("90%").font(.caption2.bold()).foregroundStyle(.orange)
                    }
                RuleMark(y: .value("88% threshold", 88))
                    .foregroundStyle(.red.opacity(0.95))
                    .lineStyle(.init(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .bottom, alignment: .trailing) {
                        Text("88%").font(.caption2.bold()).foregroundStyle(.red)
                    }
            }
            .chartYScale(domain: lower...upper)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: trendVisibleDuration)
            .chartScrollPosition(x: $trendScrollPosition)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.10))
                    AxisTick().foregroundStyle(.white.opacity(0.35))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: Array(Set([lower, 88, 90, upper])).sorted()) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.14))
                    AxisTick().foregroundStyle(.cyan.opacity(0.65))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text("\(integer(number))%")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.cyan)
                        }
                    }
                }
            }
            .chartPlotStyle { $0.background(Color.black.opacity(0.2)) }
            .frame(height: 230)
            .overlay {
                if oxygenTrend.isEmpty {
                    Label("No usable SpO₂ values in this period", systemImage: "waveform.slash")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        .padding(10).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08)))
    }

    private var trendVisibleDuration: TimeInterval {
        guard let snapshot else { return 3_600 }
        return min(3_600, max(60, snapshot.periodEnd.timeIntervalSince(snapshot.periodStart)))
    }

    private var trendResolutionLabel: String {
        guard let snapshot else { return "5-second resolution" }
        return snapshot.periodEnd.timeIntervalSince(snapshot.periodStart) <= 86_400
            ? "5-second resolution" : "1-minute resolution"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        guard let rounded = TelemetryValidation.roundedInteger(seconds) else { return "—" }
        let value = max(0, rounded)
        if value < 60 { return "\(value)s" }
        if value < 3_600 { return "\(value / 60)m \(value % 60)s" }
        if value < 86_400 { return "\(value / 3_600)h \((value % 3_600) / 60)m" }
        return "\(value / 86_400)d \((value % 86_400) / 3_600)h"
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    private func vital(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + unit
    }

    private func range(_ minimum: Double?, _ maximum: Double?, unit: String) -> String {
        guard let minimum, let maximum else { return "—" }
        return "\(integer(minimum))–\(integer(maximum))\(unit)"
    }

    private func integer(_ value: Double) -> String {
        TelemetryValidation.roundedInteger(value).map(String.init) ?? "—"
    }
}

private struct AnalysisCard<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage).font(.caption.bold()).foregroundStyle(color)
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08)))
    }
}

private struct AnalysisMetric: View {
    let label: String
    let value: String
    var detail: String? = nil
    var emphasis: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(emphasis)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .font(.callout)
    }
}

private enum AnalysisPeriod: CaseIterable, Identifiable {
    case hour, sixHours, twelveHours, day, week, month, custom
    var id: Self { self }
    var seconds: TimeInterval {
        switch self {
        case .hour: 3_600
        case .sixHours: 21_600
        case .twelveHours: 43_200
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        case .custom: 0
        }
    }
    var label: String {
        switch self {
        case .hour: "1h"
        case .sixHours: "6h"
        case .twelveHours: "12h"
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .custom: "Custom"
        }
    }
}
