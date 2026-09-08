import AppKit
import Foundation
import Observation

@MainActor @Observable
final class MonitorViewModel {
    var vitals = LiveVitals(oxygenSaturation: 98, heartRate: 124, batteryPercentage: 82, signalStrength: -54, timestamp: .now, serial: "DEMO", movement: 0)
    var readingStatus: ReadingStatus = .available
    var state: ConnectionState = .demo
    var alarmRules: [AlarmRule] = AlarmRule.defaults
    var alarms: [ActiveAlarm] = []
    var violations: [AlarmViolation] = []
    var alarmSilencedUntil: Date?
    var history: [VitalReading] = []
    var page: MonitorPage = .live
    var showingSettings = false
    var isDemoMode = true
    var region: OwletRegion = .world
    var email = ""
    var password = ""
    var refreshInterval = 5.0
    var audibleConnectionLossAlarm = true
    var movementThreshold = 50.0
    var observedMinimumRefresh: Double?
    var isTestingRefresh = false
    var refreshTestStatus = ""
    var lastError: String?
    var storageError: String?

    private let store: HistoryStore
    private let audio = AlertAudioController()
    private let clock = ContinuousClock()
    private var pollingTask: Task<Void, Never>?
    private var refreshTestTask: Task<Void, Never>?
    private var api: OwletAPI?
    private var device: OwletAPI.Device?
    private var demoPhase = 0.0
    private var violationStartedAt: [UUID: Date] = [:]
    private var violationStartedInstant: [UUID: ContinuousClock.Instant] = [:]
    private var observedViolationDuration: [UUID: TimeInterval] = [:]
    private var lastViolationSampleAt: [UUID: Date] = [:]
    private var lastViolationSampleInstant: [UUID: ContinuousClock.Instant] = [:]
    private var firedRules: Set<UUID> = []
    private var activeViolationIDs: [UUID: Int64] = [:]
    private var monitoringActivity: NSObjectProtocol?
    private var lastReceivedAt: Date?
    private var lastReceivedInstant: ContinuousClock.Instant?
    private var lastPayloadAdvancedInstant: ContinuousClock.Instant?
    private var lastSourceTimestamp: Date?
    private var consecutivePollFailures = 0

    init(store: HistoryStore) {
        self.store = store
        Self.migrateLegacyDefaults()
        if let saved = KeychainStore.load() { email = saved.email; password = saved.password }
        region = OwletRegion(rawValue: UserDefaults.standard.string(forKey: "region") ?? "World") ?? .world
        isDemoMode = UserDefaults.standard.object(forKey: "demoMode") as? Bool ?? true
        let savedRefreshInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 5
        refreshInterval = savedRefreshInterval.isFinite ? min(300, max(1, savedRefreshInterval)) : 5
        audibleConnectionLossAlarm = UserDefaults.standard.object(forKey: "audibleConnectionLossAlarm") as? Bool ?? true
        let savedMovementThreshold = UserDefaults.standard.object(forKey: "movementThreshold") as? Double ?? 50
        movementThreshold = savedMovementThreshold.isFinite ? min(1_000, max(0, savedMovementThreshold)) : 50
        if let data = UserDefaults.standard.data(forKey: "alarmRules"), var saved = try? JSONDecoder().decode([AlarmRule].self, from: data), !saved.isEmpty {
            if !UserDefaults.standard.bool(forKey: "oxygenDefault88Migrated"),
               let index = saved.firstIndex(where: { $0.name == "Low oxygen" && $0.metric == .oxygenSaturation && $0.comparison == .below && $0.threshold == 90 && $0.durationSeconds == 10 }) {
                saved[index].threshold = 88
                if let migrated = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(migrated, forKey: "alarmRules") }
            }
            alarmRules = saved
        }
        normalizeAlarmRules()
        UserDefaults.standard.set(true, forKey: "oxygenDefault88Migrated")
        loadHistory()
        violations = store.violations()
        storageError = store.storageError
    }

    func start() {
        guard pollingTask == nil, !isTestingRefresh else { return }
        preventIdleSleep()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            if isDemoMode { state = .demo }
            while !Task.isCancelled {
                if isDemoMode { accept(nextDemoReading()) } else { await pollDevice() }
                let multiplier = isDemoMode ? 1 : pow(2, Double(min(consecutivePollFailures, 4)))
                let delay = min(60, refreshInterval * multiplier)
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        refreshTestTask?.cancel()
        refreshTestTask = nil
        finishAllViolations(at: lastReceivedAt ?? .now, instant: lastReceivedInstant ?? clock.now)
        audio.stop()
        allowIdleSleep()
    }

    func reconnect() {
        stop()
        api = nil
        device = nil
        lastError = nil
        start()
    }

    func saveSettings() {
        if !isDemoMode, !email.isEmpty, !password.isEmpty {
            do { try KeychainStore.save(email: email, password: password) }
            catch { lastError = "Could not save credentials to Keychain."; return }
        }
        if !refreshInterval.isFinite { refreshInterval = 5 }
        refreshInterval = min(300, max(1, refreshInterval))
        if !movementThreshold.isFinite { movementThreshold = 50 }
        movementThreshold = min(1_000, max(0, movementThreshold))
        normalizeAlarmRules()
        UserDefaults.standard.set(region.rawValue, forKey: "region")
        UserDefaults.standard.set(isDemoMode, forKey: "demoMode")
        UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
        UserDefaults.standard.set(audibleConnectionLossAlarm, forKey: "audibleConnectionLossAlarm")
        UserDefaults.standard.set(movementThreshold, forKey: "movementThreshold")
        if let data = try? JSONEncoder().encode(alarmRules) { UserDefaults.standard.set(data, forKey: "alarmRules") }
        showingSettings = false
        reconnect()
    }

    func addAlarmRule() {
        alarmRules.append(AlarmRule(name: "New alarm", metric: .oxygenSaturation, comparison: .below, threshold: 88, durationSeconds: 10, action: .log))
    }

    func deleteAlarmRule(id: UUID) {
        finishViolation(for: id, at: .now, instant: clock.now)
        alarmRules.removeAll { $0.id == id }
        violationStartedAt[id] = nil
        violationStartedInstant[id] = nil
        observedViolationDuration[id] = nil
        lastViolationSampleAt[id] = nil
        lastViolationSampleInstant[id] = nil
        firedRules.remove(id)
    }

    func removeSavedCredentials() {
        do { try KeychainStore.removeAll() }
        catch { lastError = "Could not remove saved credentials from Keychain."; return }
        email = ""
        password = ""
    }

    func silenceAlarms() {
        alarmSilencedUntil = .now.addingTimeInterval(120)
        audio.stop()
    }

    var alarmIsSilenced: Bool { alarmSilencedUntil.map { $0 > .now } ?? false }
    var oxygenLimitLabel: String { ruleSummary(for: .oxygenSaturation) }
    var pulseLimitLabel: String { ruleSummary(for: .heartRate) }

    func aggregatedHistory(since: Date, bucketSeconds: Int) async -> [AggregatedReading] {
        let path = store.databasePath
        let bucket = max(1, bucketSeconds)
        let sampleSeconds = min(Double(bucket), max(1, refreshInterval))
        let threshold = movementThreshold
        return await Task.detached(priority: .utility) {
            HistoryAnalysisReader.aggregate(
                databasePath: path, since: since, bucketSeconds: bucket,
                sampleSeconds: sampleSeconds, movementThreshold: threshold)
        }.value
    }

    func analysis(since: Date, until: Date = .now) async -> AnalysisSnapshot {
        let lowPulse = alarmRules
            .filter { $0.enabled && $0.metric == .heartRate && $0.comparison == .below }
            .map(\.threshold).max() ?? 50
        let highPulse = alarmRules
            .filter { $0.enabled && $0.metric == .heartRate && $0.comparison == .above }
            .map(\.threshold).min() ?? 220
        let path = store.databasePath
        let sampleGap = max(10, refreshInterval * 2.5)
        let threshold = movementThreshold
        return await Task.detached(priority: .utility) {
            HistoryAnalysisReader.read(
                databasePath: path, since: since, until: until,
                maximumSampleGap: sampleGap,
                movementThreshold: threshold,
                lowPulseLimit: lowPulse, highPulseLimit: highPulse)
        }.value
    }

    func analysisOxygenTrend(since: Date, until: Date) async -> [OxygenTrendPoint] {
        let duration = max(0, until.timeIntervalSince(since))
        let bucketSeconds = duration <= 86_400 ? 5 : 60
        let limit = min(100_000, max(1, Int(ceil(duration / Double(bucketSeconds))) + 2))
        let path = store.databasePath
        let threshold = movementThreshold
        return await Task.detached(priority: .utility) {
            HistoryAnalysisReader.oxygenTrend(
                databasePath: path, since: since, until: until,
                bucketSeconds: bucketSeconds, movementThreshold: threshold,
                limit: limit)
        }.value
    }

    func reloadViolations() { violations = store.violations() }

    func testMinimumRefreshInterval() {
        guard !isTestingRefresh else { return }
        stop()
        isTestingRefresh = true
        refreshTestStatus = "Polling every second; waiting for changed values…"
        observedMinimumRefresh = nil
        preventIdleSleep()
        refreshTestTask = Task { [weak self] in
            guard let self else { return }
            var shouldRestart = true
            do {
                var previous = isDemoMode ? nextDemoReading() : try await fetchDeviceVitals()
                var lastChange = Date.now
                var shortest: TimeInterval?
                var changes = 0
                for second in 1...30 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(1))
                    let sample = isDemoMode ? nextDemoReading() : try await fetchDeviceVitals()
                    refreshTestStatus = "Testing… \(second)s / 30s, \(changes) changes"
                    if readingsDiffer(previous, sample) {
                        let interval = Date.now.timeIntervalSince(lastChange)
                        shortest = min(shortest ?? interval, interval)
                        lastChange = .now
                        previous = sample
                        changes += 1
                        accept(sample)
                        if changes >= 3 { break }
                    }
                }
                if let shortest {
                    observedMinimumRefresh = max(1, (shortest * 10).rounded() / 10)
                    refreshTestStatus = "Changed readings observed as quickly as \(observedMinimumRefresh!.formatted(.number.precision(.fractionLength(1)))) seconds."
                } else {
                    refreshTestStatus = "No changed values were returned during the 30-second test."
                }
            } catch {
                if error is CancellationError {
                    refreshTestStatus = "Refresh test cancelled."
                    shouldRestart = false
                } else {
                    refreshTestStatus = "Test failed: \(error.localizedDescription)"
                }
            }
            isTestingRefresh = false
            refreshTestTask = nil
            allowIdleSleep()
            if shouldRestart, !Task.isCancelled { start() }
        }
    }

    func useObservedRefreshInterval() {
        if let observedMinimumRefresh { refreshInterval = max(1, observedMinimumRefresh.rounded(.up)) }
    }

    private func pollDevice() async {
        do {
            accept(try await fetchDeviceVitals())
            if let device { state = .connected(device.name) }
            lastError = nil
            consecutivePollFailures = 0
        } catch {
            if case .noLiveReading? = error as? OwletAPIError {
                if let device { state = .connected(device.name) }
                lastError = error.localizedDescription
                consecutivePollFailures = 0
                readingStatus = .unavailable
                markNoActiveReading()
                return
            }
            let message = error.localizedDescription
            state = .failed(message)
            lastError = message
            consecutivePollFailures += 1
            if case .invalidCredentials? = error as? OwletAPIError {
                api = nil
                device = nil
            }
            readingStatus = lastReceivedAt == nil ? .unavailable : .stale
            markDataUnavailable()
            recordChartSample(status: readingStatus)
        }
    }

    private func fetchDeviceVitals() async throws -> LiveVitals {
        if api == nil {
            guard !email.isEmpty, !password.isEmpty else { throw OwletAPIError.invalidCredentials }
            state = .connecting
            let newAPI = OwletAPI(credentials: .init(email: email, password: password, region: region))
            try await newAPI.authenticate()
            let selected = try await newAPI.devices().first!
            api = newAPI
            device = selected
        }
        guard let api, let device else { throw OwletAPIError.noDevices }
        return try await api.vitals(for: device)
    }

    private func nextDemoReading() -> LiveVitals {
        demoPhase += 0.38
        let movement = (10...12).contains(Int(demoPhase) % 24) ? 1 : 0
        return LiveVitals(
            oxygenSaturation: 96.8 + sin(demoPhase * 0.43) * 1.1,
            heartRate: 122 + sin(demoPhase) * 7 + sin(demoPhase * 0.27) * 3,
            batteryPercentage: max(5, (vitals.batteryPercentage ?? 82) - 0.01),
            signalStrength: -54, timestamp: .now, serial: "DEMO", movement: movement,
            reportsMovementAsBoolean: true)
    }

    private func accept(_ incoming: LiveVitals) {
        let receivedAt = Date.now
        let receivedInstant = clock.now
        var reading = incoming
        reading.oxygenSaturation = min(100, max(0, reading.oxygenSaturation))
        let valuesChanged = reading.oxygenSaturation != vitals.oxygenSaturation || reading.heartRate != vitals.heartRate
        let hasSourceTimestamp = reading.timestamp != .distantPast
        let sourceAdvanced = hasSourceTimestamp && (lastSourceTimestamp.map { reading.timestamp > $0 } ?? true)
        if sourceAdvanced || (valuesChanged && (hasSourceTimestamp || lastSourceTimestamp != nil)) { lastPayloadAdvancedInstant = receivedInstant }
        lastSourceTimestamp = max(lastSourceTimestamp ?? .distantPast, reading.timestamp)
        vitals = reading
        lastReceivedAt = receivedAt
        lastReceivedInstant = receivedInstant
        readingStatus = quality(of: reading, at: receivedAt, instant: receivedInstant)
        switch readingStatus {
        case .available: evaluateAlarms()
        case .movement: markDataUnreliable()
        case .stale, .unavailable: markDataUnavailable()
        }
        recordChartSample(status: readingStatus)
    }

    private func recordChartSample(status: ReadingStatus) {
        let storedStatus: ReadingStatus = status == .movement ? .available : status
        let stored = VitalReading(timestamp: .now, oxygenSaturation: vitals.oxygenSaturation, heartRate: vitals.heartRate, deviceSerial: vitals.serial, status: storedStatus, movement: vitals.movement)
        history.append(store.insert(stored) ?? stored)
        storageError = store.storageError
        let cutoff = Date.now.addingTimeInterval(-12 * 60 * 60)
        history.removeAll { $0.timestamp < cutoff }
        let limit = historyLimit
        if history.count > limit { history.removeFirst(history.count - limit) }
    }

    private func evaluateAlarms() {
        let now = Date.now
        let nowInstant = clock.now
        var active: [ActiveAlarm] = []
        for rule in alarmRules where rule.enabled {
            if rule.isViolated(by: vitals) {
                if violationStartedAt[rule.id] == nil {
                    violationStartedAt[rule.id] = now
                    violationStartedInstant[rule.id] = nowInstant
                    observedViolationDuration[rule.id] = 0
                }
                if let previous = lastViolationSampleAt[rule.id],
                   let previousInstant = lastViolationSampleInstant[rule.id] {
                    let gap = elapsed(from: previousInstant, to: nowInstant)
                    if gap <= maximumObservedSampleGap {
                        observedViolationDuration[rule.id, default: 0] += max(0, gap)
                    } else {
                        finishViolation(for: rule.id, at: previous, instant: previousInstant)
                        firedRules.remove(rule.id)
                        violationStartedAt[rule.id] = now
                        violationStartedInstant[rule.id] = nowInstant
                        observedViolationDuration[rule.id] = 0
                    }
                }
                lastViolationSampleAt[rule.id] = now
                lastViolationSampleInstant[rule.id] = nowInstant
                let observed = observedViolationDuration[rule.id, default: 0]
                guard observed >= rule.durationSeconds else { continue }
                if !firedRules.contains(rule.id) {
                    if let started = violationStartedAt[rule.id],
                       let event = store.insertViolation(rule: rule, value: rule.value(from: vitals), deviceSerial: vitals.serial, startedAt: started) {
                        firedRules.insert(rule.id)
                        activeViolationIDs[rule.id] = event.id
                        violations.insert(event, at: 0)
                    } else {
                        storageError = store.storageError
                    }
                }
                if rule.action == .alert {
                    let value = safeRoundedInteger(rule.value(from: vitals)) ?? 0
                    active.append(.init(id: rule.id.uuidString, message: "\(rule.name.uppercased())  \(value) \(rule.metric.unit)", severity: .critical))
                }
            } else {
                finishViolation(for: rule.id, at: now, instant: nowInstant)
                violationStartedAt[rule.id] = nil
                violationStartedInstant[rule.id] = nil
                observedViolationDuration[rule.id] = nil
                lastViolationSampleAt[rule.id] = nil
                lastViolationSampleInstant[rule.id] = nil
                firedRules.remove(rule.id)
            }
        }
        alarms = active
        if active.isEmpty || alarmIsSilenced { audio.stop() } else { audio.start() }
    }

    private func quality(of reading: LiveVitals, at now: Date, instant: ContinuousClock.Instant) -> ReadingStatus {
        let payloadAge = lastPayloadAdvancedInstant.map { elapsed(from: $0, to: instant) }
        let movementAffected = MovementReliability.isAffected(
            at: now,
            currentMovement: reading.movement,
            readings: history,
            threshold: movementThreshold)
        return TelemetryValidation.status(
            oxygen: reading.oxygenSaturation,
            heartRate: reading.heartRate,
            movementDetected: movementAffected,
            sourceTimestamp: reading.timestamp,
            lastPayloadAge: payloadAge,
            now: now,
            maximumSampleGap: maximumObservedSampleGap)
    }

    private func markDataUnavailable() {
        let endedAt = lastReceivedAt ?? .now
        let endedInstant = lastReceivedInstant ?? clock.now
        let latched = alarms.filter { $0.id != "data-unavailable" }
        finishAllViolations(at: endedAt, instant: endedInstant)
        let outageSeverity: ActiveAlarm.Severity = readingStatus == .movement ? .warning : .critical
        alarms = latched + [ActiveAlarm(id: "data-unavailable", message: "DATA UNAVAILABLE", severity: outageSeverity)]
        let hasCritical = latched.contains { alarm in
            if case .critical = alarm.severity { return true }
            return false
        } || audibleConnectionLossAlarm
        if hasCritical, !alarmIsSilenced { audio.start() } else { audio.stop() }
    }

    private func markNoActiveReading() {
        let endedAt = lastReceivedAt ?? .now
        let endedInstant = lastReceivedInstant ?? clock.now
        let latched = alarms.filter { $0.id != "data-unavailable" }
        finishAllViolations(at: endedAt, instant: endedInstant)
        alarms = latched + [ActiveAlarm(id: "data-unavailable", message: "NO ACTIVE SOCK READING", severity: .warning)]
        audio.stop()
    }

    private func markDataUnreliable() {
        finishAllViolations(at: lastReceivedAt ?? .now, instant: lastReceivedInstant ?? clock.now)
        audio.stop()
    }

    private func finishAllViolations(at endedAt: Date, instant: ContinuousClock.Instant) {
        for ruleID in Array(activeViolationIDs.keys) { finishViolation(for: ruleID, at: endedAt, instant: instant) }
        violationStartedAt.removeAll()
        violationStartedInstant.removeAll()
        observedViolationDuration.removeAll()
        lastViolationSampleAt.removeAll()
        lastViolationSampleInstant.removeAll()
        firedRules.removeAll()
        alarms = []
    }

    private func finishViolation(for ruleID: UUID, at endedAt: Date, instant endedInstant: ContinuousClock.Instant) {
        guard let eventID = activeViolationIDs.removeValue(forKey: ruleID),
              let startedInstant = violationStartedInstant[ruleID] else { return }
        let actualDuration = max(0, elapsed(from: startedInstant, to: endedInstant))
        store.finishViolation(id: eventID, actualDuration: actualDuration, endedAt: endedAt)
        storageError = store.storageError
        guard let index = violations.firstIndex(where: { $0.id == eventID }) else { return }
        let event = violations[index]
        violations[index] = AlarmViolation(
            id: event.id, timestamp: event.timestamp, ruleName: event.ruleName, metric: event.metric,
            value: event.value, threshold: event.threshold,
            requiredDurationSeconds: event.requiredDurationSeconds,
            actualDurationSeconds: actualDuration, endedAt: endedAt,
            action: event.action, deviceSerial: event.deviceSerial)
    }

    private func readingsDiffer(_ lhs: LiveVitals, _ rhs: LiveVitals) -> Bool {
        lhs.oxygenSaturation != rhs.oxygenSaturation || lhs.heartRate != rhs.heartRate
    }

    private func ruleSummary(for metric: AlarmMetric) -> String {
        let rules = alarmRules.filter { $0.enabled && $0.metric == metric }
        if rules.isEmpty { return "No limits" }
        return rules.map { "\($0.comparison == .below ? "<" : ">") \(safeRoundedInteger($0.threshold) ?? 0)" }.joined(separator: "  ")
    }

    private func normalizeAlarmRules() {
        for index in alarmRules.indices {
            if !alarmRules[index].durationSeconds.isFinite { alarmRules[index].durationSeconds = 0 }
            if !alarmRules[index].threshold.isFinite {
                alarmRules[index].threshold = alarmRules[index].metric == .oxygenSaturation ? 88 : 100
            }
            alarmRules[index].durationSeconds = min(86_400, max(0, alarmRules[index].durationSeconds))
            if alarmRules[index].metric == .oxygenSaturation {
                alarmRules[index].threshold = min(100, max(0, alarmRules[index].threshold))
            } else {
                alarmRules[index].threshold = min(350, max(20, alarmRules[index].threshold))
            }
        }
    }

    private func preventIdleSleep() {
        guard monitoringActivity == nil else { return }
        monitoringActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "VitalsLoom monitoring is active")
    }

    private func allowIdleSleep() {
        if let monitoringActivity { ProcessInfo.processInfo.endActivity(monitoringActivity) }
        monitoringActivity = nil
    }

    private func loadHistory() {
        history = store.readings(since: Date.now.addingTimeInterval(-12 * 60 * 60), limit: historyLimit)
    }

    private var maximumObservedSampleGap: TimeInterval { max(10, refreshInterval * 2.5) }

    private var historyLimit: Int {
        min(50_000, max(5_000, Int((12 * 60 * 60 / max(1, refreshInterval)).rounded(.up)) + 100))
    }

    private func safeRoundedInteger(_ value: Double) -> Int? {
        TelemetryValidation.roundedInteger(value)
    }

    private func elapsed(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "vitalsLoomLegacyDefaultsMigrated") else { return }
        let legacy = UserDefaults(suiteName: "com.mdevyatov.owletmonitor")
        for key in ["region", "demoMode", "refreshInterval", "alarmRules", "oxygenDefault88Migrated"] {
            if defaults.object(forKey: key) == nil, let value = legacy?.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "vitalsLoomLegacyDefaultsMigrated")
    }
}
