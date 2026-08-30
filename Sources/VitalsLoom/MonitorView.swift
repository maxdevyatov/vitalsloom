import AppKit
import Charts
import SwiftUI

struct MonitorView: View {
    @Environment(MonitorViewModel.self) private var monitor
    @State private var selectedRange: HistoryRange = .fifteenMinutes
    @State private var selectedTrendMetric: AlarmMetric = .oxygenSaturation
    @State private var chartHover: ChartHover?

    var body: some View {
        @Bindable var monitor = monitor
        ZStack {
            Color(red: 0.018, green: 0.025, blue: 0.027).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                alarmBanner
                Group {
                    switch monitor.page {
                    case .live:
                        HStack(spacing: 0) {
                            waveformArea
                            Divider().overlay(Color.white.opacity(0.16))
                            numericColumn
                        }
                    case .history:
                        HistoricalDataView()
                    case .analysis:
                        AnalysisView()
                    case .violations:
                        AlarmLogView()
                    }
                }
                bottomBar
            }
        }
        .sheet(isPresented: $monitor.showingSettings) { SettingsView() }
        .task { monitor.start() }
        .onDisappear { monitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in monitor.stop() }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(monitor.state.label).font(.system(size: 12, weight: .bold, design: .rounded)).tracking(1.3)
            if case .connected = monitor.state { Text("Compatible device").foregroundStyle(.secondary) }
            Spacer()
            Picker("Page", selection: Binding(get: { monitor.page }, set: { monitor.page = $0 })) {
                ForEach(MonitorPage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 390)
            Text("VITALSLOOM  •  BED 01").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text(Date.now, style: .time).monospacedDigit().font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 18).frame(height: 42).background(Color(red: 0.075, green: 0.085, blue: 0.09))
    }

    @ViewBuilder private var alarmBanner: some View {
        if let alarm = monitor.alarms.first {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(alarm.message).font(.system(size: 17, weight: .heavy, design: .rounded))
                Spacer()
                if monitor.alarmIsSilenced { Label("SILENCED", systemImage: "speaker.slash.fill").font(.caption.bold()) }
            }
            .padding(.horizontal, 18).frame(height: 40).foregroundStyle(.black).background(alarmBackground(alarm.severity))
        } else if let error = monitor.lastError, !monitor.isDemoMode {
            HStack { Image(systemName: "wifi.slash"); Text(error).lineLimit(1); Spacer(); Button("Settings") { monitor.showingSettings = true }.buttonStyle(.plain) }
                .padding(.horizontal, 18).frame(height: 40).foregroundStyle(.black).background(Color.orange)
        } else if let error = monitor.storageError {
            HStack { Image(systemName: "externaldrive.badge.exclamationmark"); Text(error).lineLimit(1); Spacer() }
                .padding(.horizontal, 18).frame(height: 40).foregroundStyle(.black).background(Color.orange)
        }
    }

    private var waveformArea: some View {
        VStack(spacing: 0) {
            tracePanel(title: "Pulse", unit: "bpm", color: .green, metric: .heartRate, keyPath: \.heartRate, fallback: 100...140)
            Divider().overlay(Color.white.opacity(0.13))
            tracePanel(title: "Pleth  SpO₂", unit: "%", color: .cyan, metric: .oxygenSaturation, keyPath: \.oxygenSaturation, fallback: 94...100)
            Divider().overlay(Color.white.opacity(0.13))
            historyPanel
        }
        .frame(maxWidth: .infinity)
    }

    private func tracePanel(title: String, unit: String, color: Color, metric: AlarmMetric, keyPath: KeyPath<VitalReading, Double>, fallback: ClosedRange<Double>) -> some View {
        let data = Array(filteredHistory.suffix(90))
        let rules = monitor.alarmRules.filter { $0.enabled && $0.metric == metric }
        let scale = chartScale(data: data, keyPath: keyPath, fallback: fallback, thresholds: rules.map(\.threshold))
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(color).font(.system(size: 14, weight: .bold))
                Text(unit).foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text("min \(displayInteger(scale.dataMinimum))")
                Text("max \(displayInteger(scale.dataMaximum))")
            }
            .font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { index, reading in
                    if reading.status != .available {
                    RectangleMark(
                        xStart: .value("Quality start", reading.timestamp),
                        xEnd: .value("Quality end", qualityEnd(in: data, at: index)),
                        yStart: .value("Scale minimum", scale.domain.lowerBound),
                        yEnd: .value("Scale maximum", scale.domain.upperBound))
                    .foregroundStyle(qualityColor(reading.status).opacity(0.28))
                    }
                }
                ForEach(lineSamples(from: data, keyPath: keyPath)) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value(title, sample.value),
                        series: .value("Continuous segment", sample.segment))
                        .foregroundStyle(color).lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(rules) { rule in
                    RuleMark(y: .value("\(rule.name) threshold", rule.threshold))
                        .foregroundStyle(.red.opacity(0.85))
                        .lineStyle(.init(lineWidth: 1.5, dash: [6, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(rule.comparison == .below ? "LOW" : "HIGH") \(displayInteger(rule.threshold))")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                        }
                }
            }
            .chartYScale(domain: scale.domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.10))
                    AxisTick().foregroundStyle(.white.opacity(0.35))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.hour().minute().second()))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.18))
                    AxisTick().foregroundStyle(color.opacity(0.65))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(displayInteger(number))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color.opacity(0.9))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    chartHoverOverlay(chartID: title, data: data, proxy: proxy, geometry: geometry)
                }
            }
            .chartPlotStyle { $0.background(Color.black.opacity(0.18)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(maxHeight: .infinity)
    }

    private var historyPanel: some View {
        let data = filteredHistory
        let keyPath: KeyPath<VitalReading, Double> = selectedTrendMetric == .oxygenSaturation ? \.oxygenSaturation : \.heartRate
        let color: Color = selectedTrendMetric == .oxygenSaturation ? .cyan : .green
        let fallback: ClosedRange<Double> = selectedTrendMetric == .oxygenSaturation ? 94...100 : 100...140
        let rules = monitor.alarmRules.filter { $0.enabled && $0.metric == selectedTrendMetric }
        let scale = chartScale(data: data, keyPath: keyPath, fallback: fallback, thresholds: rules.map(\.threshold))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TRENDS").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Picker("Metric", selection: $selectedTrendMetric) {
                    Text("SpO₂").tag(AlarmMetric.oxygenSaturation)
                    Text("Pulse").tag(AlarmMetric.heartRate)
                }.pickerStyle(.segmented).frame(width: 150)
                Picker("Range", selection: $selectedRange) { ForEach(HistoryRange.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).frame(width: 250)
            }
            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { index, reading in
                    if reading.status != .available {
                    RectangleMark(
                        xStart: .value("Quality start", reading.timestamp),
                        xEnd: .value("Quality end", qualityEnd(in: data, at: index)),
                        yStart: .value("Scale minimum", scale.domain.lowerBound),
                        yEnd: .value("Scale maximum", scale.domain.upperBound))
                    .foregroundStyle(qualityColor(reading.status).opacity(0.28))
                    }
                }
                ForEach(lineSamples(from: data, keyPath: keyPath)) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value(selectedTrendMetric.rawValue, sample.value),
                        series: .value("Continuous segment", sample.segment))
                        .foregroundStyle(color)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(rules) { rule in
                    RuleMark(y: .value("\(rule.name) threshold", rule.threshold))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineStyle(.init(lineWidth: 1.5, dash: [6, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(rule.comparison == .below ? "LOW" : "HIGH") \(displayInteger(rule.threshold))")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                        }
                }
            }
            .chartYScale(domain: scale.domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.10))
                    AxisTick().foregroundStyle(.white.opacity(0.35))
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(date.formatted(.dateTime.hour().minute().second())).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.18))
                    AxisTick().foregroundStyle(color.opacity(0.65))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(displayInteger(number)).font(.system(size: 10, design: .monospaced)).foregroundStyle(color) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    chartHoverOverlay(chartID: "Trends", data: data, proxy: proxy, geometry: geometry)
                }
            }
            HStack(spacing: 16) {
                Label(selectedTrendMetric == .oxygenSaturation ? "SpO₂ %" : "Pulse bpm", systemImage: selectedTrendMetric == .oxygenSaturation ? "waveform.path.ecg" : "heart.fill").foregroundStyle(color)
                qualityLegend
                Spacer()
                Text("min \(displayInteger(scale.dataMinimum))  max \(displayInteger(scale.dataMaximum))").foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(16).frame(maxHeight: .infinity)
    }

    private var numericColumn: some View {
        VStack(spacing: 0) {
            VitalTile(label: "Pulse", value: displayedVital(monitor.vitals.heartRate), unit: "bpm", color: .green, limit: monitor.pulseLimitLabel, isAvailable: monitor.readingStatus == .available)
            Divider().overlay(Color.white.opacity(0.15))
            VitalTile(label: "SpO₂", value: displayedVital(monitor.vitals.oxygenSaturation), unit: "%", color: .cyan, limit: monitor.oxygenLimitLabel, isAvailable: monitor.readingStatus == .available)
            Divider().overlay(Color.white.opacity(0.15))
            VStack(alignment: .leading, spacing: 14) {
                Text("SOCK").font(.caption.bold()).foregroundStyle(.secondary)
                if let battery = monitor.vitals.batteryPercentage, let value = safeInteger(battery) { Label("\(value)%", systemImage: battery > 20 ? "battery.75percent" : "battery.25percent").foregroundStyle(battery > 20 ? .white : .orange) }
                if let signal = monitor.vitals.signalStrength, let value = safeInteger(signal) { Label("\(value) dBm", systemImage: "wifi").foregroundStyle(.white.opacity(0.8)) }
                if monitor.readingStatus != .available {
                    Label(monitor.readingStatus.label, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(qualityColor(monitor.readingStatus))
                }
                if monitor.vitals.timestamp == .distantPast {
                    Text("Source time unavailable").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Source updated \(monitor.vitals.timestamp.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Not a medical device").font(.caption2).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: 300)
        .background(Color(red: 0.035, green: 0.043, blue: 0.045))
    }

    private var bottomBar: some View {
        HStack(spacing: 1) {
            MonitorButton(title: monitor.alarmIsSilenced ? "Alarms Silenced" : "Silence 2 min", icon: monitor.alarmIsSilenced ? "speaker.slash.fill" : "speaker.wave.2.fill") { monitor.silenceAlarms() }
            MonitorButton(title: "History", icon: "tablecells") { monitor.page = .history }
            MonitorButton(title: "Analysis", icon: "chart.bar.xaxis") { monitor.page = .analysis }
            MonitorButton(title: "Alarm Log", icon: "list.bullet.rectangle") { monitor.page = .violations }
            MonitorButton(title: "Reconnect", icon: "arrow.clockwise") { monitor.reconnect() }
            MonitorButton(title: "Alarm Limits", icon: "slider.horizontal.3") { monitor.showingSettings = true }
            MonitorButton(title: "Main Setup", icon: "gearshape.fill") { monitor.showingSettings = true }
        }.frame(height: 62).background(Color.black)
    }

    private var filteredHistory: [VitalReading] { monitor.history.filter { $0.timestamp >= Date.now.addingTimeInterval(-selectedRange.seconds) } }
    private var statusColor: Color { if case .failed = monitor.state { return .orange }; return monitor.state == .connecting ? .yellow : .green }
    private func alarmBackground(_ severity: ActiveAlarm.Severity) -> Color {
        switch severity {
        case .warning: .orange
        case .critical: .red
        }
    }
    private func chartScale(data: [VitalReading], keyPath: KeyPath<VitalReading, Double>, fallback: ClosedRange<Double>, thresholds: [Double] = []) -> ChartScale {
        let isOxygen = keyPath == \.oxygenSaturation
        let finiteThresholds = thresholds.filter(\.isFinite)
        let validThresholds = isOxygen ? finiteThresholds.map { min(100, max(0, $0)) } : finiteThresholds
        let values = data.filter { $0.status == .available && $0[keyPath: keyPath].isFinite }.map { $0[keyPath: keyPath] }
        guard let minimum = values.min(), let maximum = values.max() else {
            let lower = max(isOxygen ? 0 : -Double.greatestFiniteMagnitude, floor(min(fallback.lowerBound, validThresholds.min() ?? fallback.lowerBound)))
            let upper = min(isOxygen ? 100 : Double.greatestFiniteMagnitude, ceil(max(fallback.upperBound, validThresholds.max() ?? fallback.upperBound)))
            return ChartScale(domain: lower...upper, ticks: [lower, ((lower + upper) / 2).rounded(), upper], dataMinimum: fallback.lowerBound, dataMaximum: fallback.upperBound)
        }
        let visibleMinimum = min(minimum, validThresholds.min() ?? minimum)
        let visibleMaximum = max(maximum, validThresholds.max() ?? maximum)
        let spread = visibleMaximum - visibleMinimum
        let minimumPadding = keyPath == \.oxygenSaturation ? 0.75 : 2.0
        let padding = max(minimumPadding, spread * 0.15)
        let lower = max(isOxygen ? 0 : -Double.greatestFiniteMagnitude, floor(visibleMinimum - padding))
        let upper = min(isOxygen ? 100 : Double.greatestFiniteMagnitude, ceil(visibleMaximum + padding))
        let midpoint = ((lower + upper) / 2).rounded()
        return ChartScale(domain: lower...upper, ticks: Array(Set([lower, midpoint, upper])).sorted(), dataMinimum: minimum, dataMaximum: maximum)
    }

    private var qualityLegend: some View {
        HStack(spacing: 10) {
            qualityLegendItem("Movement", status: .movement)
            qualityLegendItem("Stale", status: .stale)
            qualityLegendItem("Unavailable", status: .unavailable)
        }
    }

    private func qualityLegendItem(_ label: String, status: ReadingStatus) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(qualityColor(status).opacity(0.55)).frame(width: 12, height: 8); Text(label).foregroundStyle(.secondary) }
    }

    private func qualityColor(_ status: ReadingStatus) -> Color {
        switch status {
        case .available: .clear
        case .movement: .yellow
        case .stale: .orange
        case .unavailable: .red
        }
    }

    private func lineSamples(from data: [VitalReading], keyPath: KeyPath<VitalReading, Double>) -> [ChartLineSample] {
        var segment = 0
        var previousTimestamp: Date?
        var result: [ChartLineSample] = []
        for (index, reading) in data.enumerated() {
            let value = reading[keyPath: keyPath]
            guard reading.status == .available, value.isFinite else {
                previousTimestamp = nil
                continue
            }
            if previousTimestamp == nil || reading.timestamp.timeIntervalSince(previousTimestamp!) > max(10, monitor.refreshInterval * 2.5) {
                segment += 1
            }
            result.append(ChartLineSample(id: index, timestamp: reading.timestamp, value: value, segment: segment))
            previousTimestamp = reading.timestamp
        }
        return result
    }

    private func qualityEnd(in data: [VitalReading], at index: Int) -> Date {
        guard data.indices.contains(index) else { return .now }
        let start = data[index].timestamp
        let fallback = start.addingTimeInterval(max(1, monitor.refreshInterval))
        guard data.indices.contains(index + 1) else { return fallback }
        return min(data[index + 1].timestamp, start.addingTimeInterval(max(10, monitor.refreshInterval * 2.5)))
    }

    private func safeInteger(_ value: Double) -> Int? {
        guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value.rounded())
    }

    private func displayInteger(_ value: Double) -> String { safeInteger(value).map(String.init) ?? "—" }

    private func displayedVital(_ value: Double) -> String {
        guard monitor.readingStatus == .available else { return "—" }
        return displayInteger(value)
    }

    private func chartHoverOverlay(chartID: String, data: [VitalReading], proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame.map({ geometry[$0] }), plotFrame.contains(location) else {
                            if chartHover?.chartID == chartID { chartHover = nil }
                            return
                        }
                        let plotX = location.x - plotFrame.origin.x
                        guard let date: Date = proxy.value(atX: plotX),
                              let reading = data.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) else { return }
                        chartHover = ChartHover(chartID: chartID, reading: reading, location: location)
                    case .ended:
                        if chartHover?.chartID == chartID { chartHover = nil }
                    }
                }

            if let hover = chartHover, hover.chartID == chartID {
                hoverTooltip(hover.reading)
                    .fixedSize()
                    .offset(x: min(max(8, hover.location.x + 12), max(8, geometry.size.width - 190)),
                            y: min(max(8, hover.location.y - 58), max(8, geometry.size.height - 66)))
                    .allowsHitTesting(false)
            }
        }
    }

    private func hoverTooltip(_ reading: VitalReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reading.timestamp.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit())
            switch reading.status {
            case .available:
                Text("SpO₂ \(displayInteger(reading.oxygenSaturation))%  •  Pulse \(displayInteger(reading.heartRate)) bpm")
            case .movement:
                Label("Movement detected — values may be stale", systemImage: "figure.walk.motion")
                    .foregroundStyle(.yellow)
            case .stale:
                Label("Stale — no fresh device update", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            case .unavailable:
                Label("Data unavailable", systemImage: "waveform.slash")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(qualityColor(reading.status).opacity(reading.status == .available ? 0.35 : 0.9)))
    }
}

private struct ChartHover {
    let chartID: String
    let reading: VitalReading
    let location: CGPoint
}

private struct ChartLineSample: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
    let segment: Int
}

private struct ChartScale {
    let domain: ClosedRange<Double>
    let ticks: [Double]
    let dataMinimum: Double
    let dataMaximum: Double
}

private struct VitalTile: View {
    let label: String; let value: String; let unit: String; let color: Color; let limit: String; let isAvailable: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(label).font(.system(size: 17, weight: .bold)); Spacer(); Text(unit).font(.caption).foregroundStyle(.secondary) }.foregroundStyle(color)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 96, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).foregroundStyle(color.opacity(isAvailable ? 1 : 0.45))
            HStack { Image(systemName: "bell"); Text(limit) }.font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct MonitorButton: View {
    let title: String; let icon: String; let action: () -> Void
    var body: some View { Button(action: action) { VStack(spacing: 5) { Image(systemName: icon); Text(title).font(.caption) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.105, green: 0.115, blue: 0.12)) }.buttonStyle(.plain) }
}

private enum HistoryRange: CaseIterable, Identifiable {
    case fifteenMinutes, hour, twelveHours
    var id: Self { self }
    var seconds: TimeInterval { switch self { case .fifteenMinutes: 900; case .hour: 3600; case .twelveHours: 43_200 } }
    var label: String { switch self { case .fifteenMinutes: "15m"; case .hour: "1h"; case .twelveHours: "12h" } }
}
