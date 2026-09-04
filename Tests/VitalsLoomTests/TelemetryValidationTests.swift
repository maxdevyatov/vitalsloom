import Foundation
import XCTest
@testable import VitalsLoom

final class TelemetryValidationTests: XCTestCase {
    func testRejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertNil(TelemetryValidation.finiteValue(.nan, in: 1...100))
        XCTAssertNil(TelemetryValidation.finiteValue(.infinity, in: 1...100))
        XCTAssertNil(TelemetryValidation.finiteValue(101, in: 1...100))
        XCTAssertEqual(TelemetryValidation.finiteValue(88, in: 1...100), 88)
        XCTAssertNil(TelemetryValidation.roundedInteger(.infinity))
        XCTAssertNil(TelemetryValidation.roundedInteger(Double(Int.max)))
    }

    func testMovementAndFreshnessStatuses() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(TelemetryValidation.status(oxygen: 98, heartRate: 120, movementDetected: true, sourceTimestamp: now, lastPayloadAge: 0, now: now, maximumSampleGap: 10), .movement)
        XCTAssertTrue(ReadingStatus.movement.hasUsableVitals)
        XCTAssertEqual(TelemetryValidation.status(oxygen: 98, heartRate: 120, movementDetected: false, sourceTimestamp: .distantPast, lastPayloadAge: 11, now: now, maximumSampleGap: 10), .stale)
        XCTAssertEqual(TelemetryValidation.status(oxygen: 98, heartRate: 120, movementDetected: false, sourceTimestamp: now, lastPayloadAge: 5, now: now, maximumSampleGap: 10), .available)
        XCTAssertEqual(TelemetryValidation.status(oxygen: 98, heartRate: 120, movementDetected: false, sourceTimestamp: now.addingTimeInterval(-61), lastPayloadAge: 0, now: now, maximumSampleGap: 10), .stale)
        XCTAssertEqual(TelemetryValidation.status(oxygen: 98, heartRate: 120, movementDetected: true, sourceTimestamp: now.addingTimeInterval(-61), lastPayloadAge: 0, now: now, maximumSampleGap: 10), .stale)
        XCTAssertEqual(TelemetryValidation.status(oxygen: .nan, heartRate: 120, movementDetected: false, sourceTimestamp: now, lastPayloadAge: 0, now: now, maximumSampleGap: 10), .unavailable)
    }

    func testMovementReliabilityUsesCurrentThreshold() {
        XCTAssertFalse(MovementReliability.exceedsThreshold(50, threshold: 50))
        XCTAssertTrue(MovementReliability.exceedsThreshold(51, threshold: 50))
        XCTAssertFalse(MovementReliability.exceedsThreshold(51, threshold: 60))
        XCTAssertFalse(MovementReliability.exceedsThreshold(nil, threshold: 50))
    }

    func testMovementReliabilityExpandsAndMergesAffectedIntervals() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let readings = [
            VitalReading(timestamp: origin, oxygenSaturation: 98, heartRate: 120, deviceSerial: "TEST", movement: 80),
            VitalReading(timestamp: origin.addingTimeInterval(40), oxygenSaturation: 97, heartRate: 121, deviceSerial: "TEST", movement: 70)
        ]
        let intervals = MovementReliability.affectedIntervals(in: readings, threshold: 50)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start, origin.addingTimeInterval(-15))
        XCTAssertEqual(intervals[0].end, origin.addingTimeInterval(70))
        XCTAssertTrue(MovementReliability.isAffected(at: origin.addingTimeInterval(25), readings: readings, threshold: 50))
        XCTAssertFalse(MovementReliability.isAffected(at: origin.addingTimeInterval(71), readings: readings, threshold: 50))
    }

    func testDefaultOxygenAlarmUsesStrict88PercentThreshold() {
        let rule = AlarmRule.defaults.first { $0.metric == .oxygenSaturation }!
        let atThreshold = LiveVitals(oxygenSaturation: 88, heartRate: 100, batteryPercentage: nil, signalStrength: nil, timestamp: .now, serial: "TEST", movement: 0)
        var belowThreshold = atThreshold
        belowThreshold.oxygenSaturation = 87
        XCTAssertFalse(rule.isViolated(by: atThreshold))
        XCTAssertTrue(rule.isViolated(by: belowThreshold))
    }

    func testAnalysisFractionsAreBounded() {
        let end = Date.now
        let snapshot = AnalysisSnapshot(
            periodStart: end.addingTimeInterval(-100), periodEnd: end, sampleCount: 1,
            monitoredDuration: 200, availableDuration: 150, movementDuration: 0, staleUnavailableDuration: 0,
            timeBelow90: 200, timeBelow88: 200,
            longestBelow90Duration: 100, longestBelow88Duration: 50,
            averageOxygen: 88, minimumOxygen: 87, maximumOxygen: 89,
            averageHeartRate: 100, minimumHeartRate: 90, maximumHeartRate: 110,
            pulseOutsideLimitsDuration: 0, lowPulseLimit: 50, highPulseLimit: 220,
            alarmCount: 0, activeAlarmCount: 0, completedAlarmDuration: 0)
        XCTAssertEqual(snapshot.coverageFraction, 1)
        XCTAssertEqual(snapshot.availabilityFraction, 0.75)
        XCTAssertEqual(snapshot.below88Fraction, 1)
    }
}
