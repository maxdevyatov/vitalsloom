import SwiftUI

struct AlarmLogView: View {
    @Environment(MonitorViewModel.self) private var monitor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ALARM VIOLATIONS").font(.headline).foregroundStyle(.red)
                Text("\(monitor.violations.count) events").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { monitor.reloadViolations() }
            }.padding(16).background(Color.white.opacity(0.045))
            Table(monitor.violations) {
                TableColumn("Time") { event in Text(event.timestamp.formatted(date: .abbreviated, time: .standard)).monospacedDigit() }.width(min: 155, ideal: 185)
                TableColumn("Rule") { event in Text(event.ruleName) }.width(min: 120)
                TableColumn("Metric") { event in Text(event.metric) }.width(min: 70)
                TableColumn("Value") { event in Text(event.value.formatted(.number.precision(.fractionLength(1)))).foregroundStyle(.red) }.width(min: 60)
                TableColumn("Threshold") { event in Text(event.threshold.formatted(.number.precision(.fractionLength(1)))) }.width(min: 70)
                TableColumn("Required") { event in Text(duration(event.requiredDurationSeconds)) }.width(min: 70)
                TableColumn("Actual") { event in
                    if let duration = event.actualDurationSeconds { Text(duration.formatted(.number.precision(.fractionLength(1))) + "s") }
                    else { Text("—").foregroundStyle(.secondary) }
                }.width(min: 70)
                TableColumn("Ended") { event in
                    if let endedAt = event.endedAt { Text(endedAt.formatted(date: .omitted, time: .standard)).monospacedDigit() }
                    else { Text("Active").foregroundStyle(.orange) }
                }.width(min: 90)
                TableColumn("Action") { event in Text(event.action) }.width(min: 110)
                TableColumn("Device") { event in Text(maskedSerial(event.deviceSerial)) }.width(min: 100)
            }
            .overlay { if monitor.violations.isEmpty { ContentUnavailableView("No alarm violations", systemImage: "checkmark.shield") } }
        }
    }

    private func duration(_ seconds: Double) -> String {
        guard seconds >= 0, let rounded = TelemetryValidation.roundedInteger(seconds) else { return "—" }
        return "\(rounded)s"
    }

    private func maskedSerial(_ serial: String) -> String {
        guard serial.count > 4 else { return "••••" }
        return "••••" + serial.suffix(4)
    }
}
