import SwiftUI

struct SettingsView: View {
    @Environment(MonitorViewModel.self) private var monitor
    @State private var isDemoMode = true
    @State private var region: OwletRegion = .world
    @State private var email = ""
    @State private var password = ""
    @State private var refreshInterval = 5.0
    @State private var alarmRules: [AlarmRule] = []
    @State private var didLoad = false
    @State private var confirmCredentialRemoval = false

    var body: some View {
        Form {
            Section("Compatible Device Account") {
                Toggle("Use demo data", isOn: $isDemoMode)
                Picker("Region", selection: $region) { ForEach(OwletRegion.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Email", text: $email).textContentType(.emailAddress).disabled(isDemoMode)
                SecureField("Password", text: $password).textContentType(.password).disabled(isDemoMode)
                HStack {
                    Text("Credentials are stored in the macOS Keychain.")
                    Spacer()
                    Button("Delete from Keychain now…", role: .destructive) { confirmCredentialRemoval = true }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = monitor.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Compatibility & Safety") {
                Text("VitalsLoom is independent, unofficial software and is not affiliated with, sponsored by, or endorsed by Owlet Baby Care, Inc. Owlet and Dream Sock are trademarks of their owner and are referenced only to describe compatibility.")
                Text("Use only hardware and an account you own or are authorized to access. The unofficial integration can change, become unavailable, or be restricted by applicable service terms.")
                Text("Not a medical device. Readings and alarms can be delayed, inaccurate, unavailable, or fail. Never rely on VitalsLoom for diagnosis, treatment, supervision, emergency decisions, or safety-critical monitoring.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Section("Refresh Interval") {
                LabeledContent("Poll and update charts every") {
                    TextField("Seconds", value: $refreshInterval, format: .number.precision(.fractionLength(0...1))).frame(width: 75)
                    Text("seconds")
                }
                HStack {
                    Button(monitor.isTestingRefresh ? "Testing…" : "Test current saved connection") { monitor.testMinimumRefreshInterval() }
                        .disabled(monitor.isTestingRefresh || (!monitor.isDemoMode && (monitor.email.isEmpty || monitor.password.isEmpty)))
                    if monitor.observedMinimumRefresh != nil {
                        Button("Use result") {
                            monitor.useObservedRefreshInterval()
                            refreshInterval = monitor.refreshInterval
                        }
                    }
                }
                if !monitor.refreshTestStatus.isEmpty { Text(monitor.refreshTestStatus).font(.caption).foregroundStyle(.secondary) }
                Text("The test uses the currently saved connection settings. Save new account settings before testing them. Each successful poll updates the gauges and charts together with one timestamp. One second is the enforced minimum.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($alarmRules) { $rule in
                    AlarmRuleEditor(rule: $rule) {
                        alarmRules.removeAll { $0.id == rule.id }
                    }
                }
                Button("Add alarm rule", systemImage: "plus") {
                    alarmRules.append(AlarmRule(name: "New alarm", metric: .oxygenSaturation, comparison: .below, threshold: 88, durationSeconds: 10, action: .log))
                }
            } header: {
                Text("Alarm Rules")
            } footer: {
                Text("Log only records one event per continuous observed violation. Log + loud alert also sounds repeatedly after fresh samples violate the threshold for the configured duration. Monitoring prevents idle system sleep and app audio is not suppressed by Focus/DND; macOS cannot override muted output or an explicit/manual sleep.")
            }

            HStack {
                Spacer()
                Button("Cancel") { monitor.showingSettings = false }.keyboardShortcut(.cancelAction)
                Button("Save & Connect") {
                    monitor.isDemoMode = isDemoMode
                    monitor.region = region
                    monitor.email = email
                    monitor.password = password
                    monitor.refreshInterval = refreshInterval
                    monitor.alarmRules = alarmRules
                    monitor.saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 720, minHeight: 640)
        .onAppear {
            guard !didLoad else { return }
            isDemoMode = monitor.isDemoMode
            region = monitor.region
            email = monitor.email
            password = monitor.password
            refreshInterval = monitor.refreshInterval
            alarmRules = monitor.alarmRules
            didLoad = true
        }
        .confirmationDialog(
            "Delete saved credentials now?",
            isPresented: $confirmCredentialRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete from Keychain", role: .destructive) {
                monitor.removeSavedCredentials()
                if monitor.email.isEmpty, monitor.password.isEmpty {
                    email = ""
                    password = ""
                }
            }
            Button("Keep Credentials", role: .cancel) {}
        } message: {
            Text("This takes effect immediately and is not undone by Cancel.")
        }
    }
}

private struct AlarmRuleEditor: View {
    @Binding var rule: AlarmRule
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $rule.enabled).labelsHidden()
                TextField("Rule name", text: $rule.name).font(.headline)
                Spacer()
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            HStack {
                Picker("Metric", selection: $rule.metric) { ForEach(AlarmMetric.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                Picker("Condition", selection: $rule.comparison) { ForEach(AlarmComparison.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 145)
                LabeledContent("Value") { TextField("", value: $rule.threshold, format: .number).frame(width: 55); Text(rule.metric.unit) }
            }
            HStack {
                LabeledContent("For at least") { TextField("", value: $rule.durationSeconds, format: .number).frame(width: 55); Text("seconds") }
                Picker("Action", selection: $rule.action) { ForEach(AlarmAction.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 220)
            }
        }
        .padding(.vertical, 5)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}
