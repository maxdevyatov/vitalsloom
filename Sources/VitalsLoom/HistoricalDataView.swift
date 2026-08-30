import SwiftUI

struct HistoricalDataView: View {
    @Environment(MonitorViewModel.self) private var monitor
    @State private var range: HistoricalRange = .twelveHours
    @State private var aggregation = 60
    @State private var rows: [AggregatedReading] = []
    @State private var reloadGeneration = 0

    private var buckets: [Int] {
        Array(Set([max(1, Int(monitor.refreshInterval.rounded(.up))), 60, 300])).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HISTORICAL VITALS").font(.headline).foregroundStyle(.cyan)
                Spacer()
                Picker("Range", selection: $range) { ForEach(HistoricalRange.allCases) { Text($0.label).tag($0) } }.frame(width: 150)
                Picker("Aggregation", selection: $aggregation) {
                    ForEach(buckets, id: \.self) { seconds in Text(bucketLabel(seconds)).tag(seconds) }
                }.frame(width: 190)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
            }.padding(16).background(Color.white.opacity(0.045))

            Table(rows) {
                TableColumn("Time") { row in Text(row.timestamp.formatted(date: .abbreviated, time: .standard)).monospacedDigit() }.width(min: 155, ideal: 185)
                TableColumn("SpO₂ avg") { row in Text(row.averageOxygen.formatted(.number.precision(.fractionLength(1)))) }.width(min: 75)
                TableColumn("SpO₂ min") { row in Text(row.minimumOxygen.formatted(.number.precision(.fractionLength(1)))).foregroundStyle(.cyan) }.width(min: 75)
                TableColumn("SpO₂ max") { row in Text(row.maximumOxygen.formatted(.number.precision(.fractionLength(1)))) }.width(min: 75)
                TableColumn("Pulse avg") { row in Text(row.averageHeartRate.formatted(.number.precision(.fractionLength(1)))) }.width(min: 75)
                TableColumn("Pulse min") { row in Text(row.minimumHeartRate.formatted(.number.precision(.fractionLength(1)))) }.width(min: 75)
                TableColumn("Pulse max") { row in Text(row.maximumHeartRate.formatted(.number.precision(.fractionLength(1)))).foregroundStyle(.green) }.width(min: 75)
                TableColumn("Samples") { row in Text("\(row.sampleCount)") }.width(min: 60)
            }
            .overlay { if rows.isEmpty { ContentUnavailableView("No historical readings", systemImage: "chart.xyaxis.line") } }
        }
        .onAppear {
            if !buckets.contains(aggregation) { aggregation = buckets.first ?? 60 }
            reloadDeferred()
        }
        .onChange(of: range) { reloadDeferred() }
        .onChange(of: aggregation) { reloadDeferred() }
    }

    private func bucketLabel(_ seconds: Int) -> String {
        if seconds == Int(monitor.refreshInterval.rounded(.up)) { return "Raw (\(seconds)s refresh)" }
        return seconds >= 60 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let result = await monitor.aggregatedHistory(since: Date.now.addingTimeInterval(-range.seconds), bucketSeconds: aggregation)
        guard generation == reloadGeneration, !Task.isCancelled else { return }
        rows = result
    }

    private func reloadDeferred() {
        Task { await reload() }
    }
}

private enum HistoricalRange: CaseIterable, Identifiable {
    case hour, twelveHours, day, week, month
    var id: Self { self }
    var seconds: TimeInterval { switch self { case .hour: 3_600; case .twelveHours: 43_200; case .day: 86_400; case .week: 604_800; case .month: 2_592_000 } }
    var label: String { switch self { case .hour: "1 hour"; case .twelveHours: "12 hours"; case .day: "24 hours"; case .week: "7 days"; case .month: "30 days" } }
}
