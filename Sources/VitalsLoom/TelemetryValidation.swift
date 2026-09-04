import Foundation

enum TelemetryValidation {
    static func finiteValue(_ value: Double, in range: ClosedRange<Double>) -> Double? {
        guard value.isFinite, range.contains(value) else { return nil }
        return value
    }

    static func roundedInteger(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    static func status(
        oxygen: Double,
        heartRate: Double,
        movementDetected: Bool,
        sourceTimestamp: Date,
        lastPayloadAge: TimeInterval?,
        now: Date,
        maximumSampleGap: TimeInterval
    ) -> ReadingStatus {
        guard finiteValue(oxygen, in: 1...100) != nil,
              finiteValue(heartRate, in: 20...350) != nil else { return .unavailable }
        if sourceTimestamp != .distantPast,
           now.timeIntervalSince(sourceTimestamp) > max(60, maximumSampleGap * 2) { return .stale }
        guard let lastPayloadAge, lastPayloadAge >= 0,
              lastPayloadAge <= maximumSampleGap else { return .stale }
        return movementDetected ? .movement : .available
    }
}
