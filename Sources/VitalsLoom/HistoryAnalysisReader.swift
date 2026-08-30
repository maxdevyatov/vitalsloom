import CSQLite
import Foundation

enum HistoryAnalysisReader {
    static func aggregate(databasePath: String, since: Date, bucketSeconds: Int, limit: Int = 5_000) -> [AggregatedReading] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = """
        SELECT CAST(timestamp / ? AS INTEGER) * ? AS bucket,
               AVG(oxygen), MIN(oxygen), MAX(oxygen),
               AVG(heart_rate), MIN(heart_rate), MAX(heart_rate), COUNT(*)
        FROM readings WHERE timestamp >= ? AND status = 'available'
        GROUP BY CAST(timestamp / ? AS INTEGER)
        ORDER BY bucket DESC LIMIT ?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(bucketSeconds))
        sqlite3_bind_int(statement, 2, Int32(bucketSeconds))
        sqlite3_bind_double(statement, 3, since.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Int32(bucketSeconds))
        sqlite3_bind_int(statement, 5, Int32(limit))
        var result: [AggregatedReading] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(AggregatedReading(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                averageOxygen: sqlite3_column_double(statement, 1), minimumOxygen: sqlite3_column_double(statement, 2), maximumOxygen: sqlite3_column_double(statement, 3),
                averageHeartRate: sqlite3_column_double(statement, 4), minimumHeartRate: sqlite3_column_double(statement, 5), maximumHeartRate: sqlite3_column_double(statement, 6),
                sampleCount: Int(sqlite3_column_int(statement, 7))))
        }
        return result
    }

    static func read(
        databasePath: String,
        since: Date,
        until: Date,
        maximumSampleGap: TimeInterval,
        lowPulseLimit: Double,
        highPulseLimit: Double
    ) -> AnalysisSnapshot {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return empty(since: since, until: until, lowPulseLimit: lowPulseLimit, highPulseLimit: highPulseLimit)
        }
        defer { sqlite3_close(database) }

        var sampleCount = 0
        var monitoredDuration = 0.0
        var availableDuration = 0.0
        var movementDuration = 0.0
        var staleUnavailableDuration = 0.0
        var timeBelow90 = 0.0
        var timeBelow88 = 0.0
        var averageOxygen: Double?
        var minimumOxygen: Double?
        var maximumOxygen: Double?
        var averageHeartRate: Double?
        var minimumHeartRate: Double?
        var maximumHeartRate: Double?
        var pulseOutsideLimitsDuration = 0.0
        var alarmCount = 0
        var activeAlarmCount = 0
        var completedAlarmDuration = 0.0

        var statement: OpaquePointer?
        let readingsSQL = """
        WITH ordered AS (
            SELECT timestamp, oxygen, heart_rate, status,
                   COALESCE(LEAD(timestamp) OVER (ORDER BY timestamp), ?) AS next_timestamp
            FROM readings
            WHERE timestamp >= ? AND timestamp <= ?
        ), spans AS (
            SELECT oxygen, heart_rate, status,
                   MIN(MAX(next_timestamp - timestamp, 0), ?) AS seconds
            FROM ordered
        )
        SELECT COUNT(*),
               COALESCE(SUM(seconds), 0),
               COALESCE(SUM(CASE WHEN status = 'available' THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN status = 'movement' THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN status IN ('stale', 'unavailable') THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN status = 'available' AND oxygen < 90 THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN status = 'available' AND oxygen < 88 THEN seconds ELSE 0 END), 0),
               AVG(CASE WHEN status = 'available' THEN oxygen END),
               MIN(CASE WHEN status = 'available' THEN oxygen END),
               MAX(CASE WHEN status = 'available' THEN oxygen END),
               AVG(CASE WHEN status = 'available' THEN heart_rate END),
               MIN(CASE WHEN status = 'available' THEN heart_rate END),
               MAX(CASE WHEN status = 'available' THEN heart_rate END),
               COALESCE(SUM(CASE WHEN status = 'available' AND (heart_rate < ? OR heart_rate > ?) THEN seconds ELSE 0 END), 0)
        FROM spans;
        """
        if sqlite3_prepare_v2(database, readingsSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, maximumSampleGap)
            sqlite3_bind_double(statement, 5, lowPulseLimit)
            sqlite3_bind_double(statement, 6, highPulseLimit)
            if sqlite3_step(statement) == SQLITE_ROW {
                sampleCount = Int(sqlite3_column_int(statement, 0))
                monitoredDuration = sqlite3_column_double(statement, 1)
                availableDuration = sqlite3_column_double(statement, 2)
                movementDuration = sqlite3_column_double(statement, 3)
                staleUnavailableDuration = sqlite3_column_double(statement, 4)
                timeBelow90 = sqlite3_column_double(statement, 5)
                timeBelow88 = sqlite3_column_double(statement, 6)
                averageOxygen = optionalDouble(statement, 7)
                minimumOxygen = optionalDouble(statement, 8)
                maximumOxygen = optionalDouble(statement, 9)
                averageHeartRate = optionalDouble(statement, 10)
                minimumHeartRate = optionalDouble(statement, 11)
                maximumHeartRate = optionalDouble(statement, 12)
                pulseOutsideLimitsDuration = sqlite3_column_double(statement, 13)
            }
        }
        sqlite3_finalize(statement)

        statement = nil
        let violationsSQL = """
        SELECT COUNT(*),
               COALESCE(SUM(CASE WHEN ended_at IS NULL OR actual_duration IS NULL THEN 0 ELSE
                   actual_duration * MAX(0, MIN(ended_at, ?) - MAX(timestamp, ?)) /
                   MAX(ended_at - timestamp, actual_duration, 0.001) END), 0),
               COALESCE(SUM(CASE WHEN timestamp <= ? AND (ended_at IS NULL OR ended_at > ?) THEN 1 ELSE 0 END), 0)
        FROM alarm_violations
        WHERE timestamp <= ? AND COALESCE(ended_at, ?) >= ?;
        """
        if sqlite3_prepare_v2(database, violationsSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, since.timeIntervalSince1970)
            if sqlite3_step(statement) == SQLITE_ROW {
                alarmCount = Int(sqlite3_column_int(statement, 0))
                completedAlarmDuration = sqlite3_column_double(statement, 1)
                activeAlarmCount = Int(sqlite3_column_int(statement, 2))
            }
        }
        sqlite3_finalize(statement)

        return AnalysisSnapshot(
            periodStart: since, periodEnd: until, sampleCount: sampleCount,
            monitoredDuration: monitoredDuration, availableDuration: availableDuration,
            movementDuration: movementDuration, staleUnavailableDuration: staleUnavailableDuration,
            timeBelow90: timeBelow90, timeBelow88: timeBelow88,
            averageOxygen: averageOxygen, minimumOxygen: minimumOxygen, maximumOxygen: maximumOxygen,
            averageHeartRate: averageHeartRate, minimumHeartRate: minimumHeartRate, maximumHeartRate: maximumHeartRate,
            pulseOutsideLimitsDuration: pulseOutsideLimitsDuration,
            lowPulseLimit: lowPulseLimit, highPulseLimit: highPulseLimit,
            alarmCount: alarmCount, activeAlarmCount: activeAlarmCount, completedAlarmDuration: completedAlarmDuration)
    }

    private static func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private static func empty(since: Date, until: Date, lowPulseLimit: Double, highPulseLimit: Double) -> AnalysisSnapshot {
        AnalysisSnapshot(
            periodStart: since, periodEnd: until, sampleCount: 0,
            monitoredDuration: 0, availableDuration: 0, movementDuration: 0, staleUnavailableDuration: 0,
            timeBelow90: 0, timeBelow88: 0,
            averageOxygen: nil, minimumOxygen: nil, maximumOxygen: nil,
            averageHeartRate: nil, minimumHeartRate: nil, maximumHeartRate: nil,
            pulseOutsideLimitsDuration: 0, lowPulseLimit: lowPulseLimit, highPulseLimit: highPulseLimit,
            alarmCount: 0, activeAlarmCount: 0, completedAlarmDuration: 0)
    }
}
