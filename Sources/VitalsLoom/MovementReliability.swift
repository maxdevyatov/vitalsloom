import Foundation

enum MovementReliability {
    static let preRoll: TimeInterval = 15
    static let recovery: TimeInterval = 30

    static func exceedsThreshold(_ movement: Int?, threshold: Double) -> Bool {
        guard threshold.isFinite, let movement else { return false }
        return Double(movement) > threshold
    }

    static func isAffected(
        at timestamp: Date,
        currentMovement: Int? = nil,
        readings: [VitalReading],
        threshold: Double
    ) -> Bool {
        if exceedsThreshold(currentMovement, threshold: threshold) { return true }
        guard threshold.isFinite else { return false }
        let earliestSpike = timestamp.addingTimeInterval(-recovery)
        let latestSpike = timestamp.addingTimeInterval(preRoll)
        return readings.contains { reading in
            reading.status.hasUsableVitals &&
            reading.timestamp >= earliestSpike && reading.timestamp <= latestSpike &&
            exceedsThreshold(reading.movement, threshold: threshold)
        }
    }

    static func affectedIntervals(
        in readings: [VitalReading],
        threshold: Double
    ) -> [DateInterval] {
        guard threshold.isFinite else { return [] }
        let spikes = readings
            .filter { $0.status.hasUsableVitals && exceedsThreshold($0.movement, threshold: threshold) }
            .map(\.timestamp)
            .sorted()
        var result: [DateInterval] = []
        for spike in spikes {
            let interval = DateInterval(
                start: spike.addingTimeInterval(-preRoll),
                end: spike.addingTimeInterval(recovery))
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    static func displayStatus(
        for reading: VitalReading,
        among readings: [VitalReading],
        threshold: Double
    ) -> ReadingStatus {
        switch reading.status {
        case .stale, .unavailable:
            return reading.status
        case .available, .movement:
            return isAffected(at: reading.timestamp, readings: readings, threshold: threshold) ? .movement : .available
        }
    }

    /// Bind threshold, recovery, then pre-roll for the three placeholders.
    static func sqlAffectedExpression(readingAlias: String, spikeAlias: String = "movement_spike") -> String {
        """
        EXISTS (
            SELECT 1 FROM readings \(spikeAlias)
            WHERE \(spikeAlias).status IN ('available', 'movement')
              AND COALESCE(\(spikeAlias).movement, 0) > ?
              AND \(spikeAlias).timestamp BETWEEN \(readingAlias).timestamp - ? AND \(readingAlias).timestamp + ?
        )
        """
    }
}
