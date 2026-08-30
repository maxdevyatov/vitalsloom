import Foundation
struct VitalReading: Identifiable, Sendable {
    let id: Int64
    let timestamp: Date
    let oxygenSaturation: Double
    let heartRate: Double
    let deviceSerial: String
    let status: ReadingStatus

    init(id: Int64 = 0, timestamp: Date = .now, oxygenSaturation: Double, heartRate: Double, deviceSerial: String, status: ReadingStatus = .available) {
        self.id = id
        self.timestamp = timestamp
        self.oxygenSaturation = oxygenSaturation
        self.heartRate = heartRate
        self.deviceSerial = deviceSerial
        self.status = status
    }
}

struct LiveVitals: Sendable {
    var oxygenSaturation: Double
    var heartRate: Double
    var batteryPercentage: Double?
    var signalStrength: Double?
    var timestamp: Date
    var serial: String
    var movement: Int?
}

enum ReadingStatus: String, Codable, Sendable {
    case available
    case movement
    case stale
    case unavailable

    var label: String {
        switch self {
        case .available: "Available"
        case .movement: "Movement"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
    }
}

enum AlarmMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case oxygenSaturation = "SpO₂"
    case heartRate = "Pulse"
    var id: Self { self }
    var unit: String { self == .oxygenSaturation ? "%" : "bpm" }
}

enum AlarmComparison: String, CaseIterable, Codable, Identifiable, Sendable {
    case below = "Below"
    case above = "Above"
    var id: Self { self }
}

enum AlarmAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case log = "Log only"
    case alert = "Log + loud alert"
    var id: Self { self }
}

struct AlarmRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var metric: AlarmMetric
    var comparison: AlarmComparison
    var threshold: Double
    var durationSeconds: Double
    var action: AlarmAction
    var enabled = true

    static let defaults = [
        AlarmRule(name: "Low oxygen", metric: .oxygenSaturation, comparison: .below, threshold: 88, durationSeconds: 10, action: .alert),
        AlarmRule(name: "Low pulse", metric: .heartRate, comparison: .below, threshold: 50, durationSeconds: 10, action: .alert),
        AlarmRule(name: "High pulse", metric: .heartRate, comparison: .above, threshold: 220, durationSeconds: 10, action: .alert)
    ]

    func value(from vitals: LiveVitals) -> Double {
        metric == .oxygenSaturation ? vitals.oxygenSaturation : vitals.heartRate
    }

    func isViolated(by vitals: LiveVitals) -> Bool {
        let current = value(from: vitals)
        return comparison == .below ? current < threshold : current > threshold
    }
}

struct AlarmViolation: Identifiable, Sendable {
    let id: Int64
    let timestamp: Date
    let ruleName: String
    let metric: String
    let value: Double
    let threshold: Double
    let requiredDurationSeconds: Double
    let actualDurationSeconds: Double?
    let endedAt: Date?
    let action: String
    let deviceSerial: String
}

struct AggregatedReading: Identifiable, Sendable {
    var id: Date { timestamp }
    let timestamp: Date
    let averageOxygen: Double
    let minimumOxygen: Double
    let maximumOxygen: Double
    let averageHeartRate: Double
    let minimumHeartRate: Double
    let maximumHeartRate: Double
    let sampleCount: Int
}

struct AnalysisSnapshot: Sendable {
    let periodStart: Date
    let periodEnd: Date
    let sampleCount: Int
    let monitoredDuration: TimeInterval
    let availableDuration: TimeInterval
    let movementDuration: TimeInterval
    let staleUnavailableDuration: TimeInterval
    let timeBelow90: TimeInterval
    let timeBelow88: TimeInterval
    let averageOxygen: Double?
    let minimumOxygen: Double?
    let maximumOxygen: Double?
    let averageHeartRate: Double?
    let minimumHeartRate: Double?
    let maximumHeartRate: Double?
    let pulseOutsideLimitsDuration: TimeInterval
    let lowPulseLimit: Double
    let highPulseLimit: Double
    let alarmCount: Int
    let activeAlarmCount: Int
    let completedAlarmDuration: TimeInterval

    var requestedDuration: TimeInterval { max(0, periodEnd.timeIntervalSince(periodStart)) }
    var coverageFraction: Double { requestedDuration > 0 ? min(1, monitoredDuration / requestedDuration) : 0 }
    var availabilityFraction: Double { monitoredDuration > 0 ? min(1, availableDuration / monitoredDuration) : 0 }
    var below90Fraction: Double { availableDuration > 0 ? min(1, timeBelow90 / availableDuration) : 0 }
    var below88Fraction: Double { availableDuration > 0 ? min(1, timeBelow88 / availableDuration) : 0 }
}

enum MonitorPage: String, CaseIterable, Identifiable {
    case live = "Live"
    case history = "History"
    case analysis = "Analysis"
    case violations = "Alarm Log"
    var id: Self { self }
}

enum OwletRegion: String, CaseIterable, Codable, Identifiable, Sendable {
    case world = "World"
    case europe = "Europe"
    var id: Self { self }
}

struct OwletCredentials: Sendable {
    var email: String
    var password: String
    var region: OwletRegion
}

enum ConnectionState: Equatable {
    case demo
    case connecting
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .demo: "DEMO"
        case .connecting: "CONNECTING"
        case .connected: "ONLINE"
        case .failed: "OFFLINE"
        }
    }
}

struct ActiveAlarm: Identifiable, Equatable {
    enum Severity { case warning, critical }
    let id: String
    let message: String
    let severity: Severity
}
