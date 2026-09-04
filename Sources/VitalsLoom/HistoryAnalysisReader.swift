import CSQLite
import Foundation

enum HistoryAnalysisReader {
    static func oxygenTrend(databasePath: String, since: Date, until: Date, bucketSeconds: Int, movementThreshold: Double, limit: Int = 5_000) -> [OxygenTrendPoint] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let movementAffected = MovementReliability.sqlAffectedExpression(readingAlias: "r")
        let sql = """
        WITH classified AS (
            SELECT r.timestamp, r.oxygen,
                   CASE WHEN \(movementAffected) THEN 0 ELSE 1 END AS reliable
            FROM readings r
            WHERE r.timestamp >= ? AND r.timestamp <= ?
              AND r.status IN ('available', 'movement')
        )
        SELECT CAST(timestamp / ? AS INTEGER) * ? AS bucket, AVG(oxygen)
        FROM classified
        WHERE reliable = 1
        GROUP BY CAST(timestamp / ? AS INTEGER)
        ORDER BY bucket ASC LIMIT ?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, movementThreshold)
        sqlite3_bind_double(statement, 2, MovementReliability.recovery)
        sqlite3_bind_double(statement, 3, MovementReliability.preRoll)
        sqlite3_bind_double(statement, 4, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, until.timeIntervalSince1970)
        sqlite3_bind_int(statement, 6, Int32(bucketSeconds))
        sqlite3_bind_int(statement, 7, Int32(bucketSeconds))
        sqlite3_bind_int(statement, 8, Int32(bucketSeconds))
        sqlite3_bind_int(statement, 9, Int32(limit))
        var result: [OxygenTrendPoint] = []
        var previousTimestamp: Date?
        var segment = 0
        let maximumGap = max(10, Double(bucketSeconds) * 2.5)
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            if previousTimestamp == nil || timestamp.timeIntervalSince(previousTimestamp!) > maximumGap { segment += 1 }
            result.append(OxygenTrendPoint(
                timestamp: timestamp,
                oxygenSaturation: sqlite3_column_double(statement, 1),
                segment: segment))
            previousTimestamp = timestamp
        }
        return result
    }

    static func aggregate(databasePath: String, since: Date, bucketSeconds: Int, sampleSeconds: TimeInterval, movementThreshold: Double, limit: Int = 5_000) -> [AggregatedReading] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let movementAffected = MovementReliability.sqlAffectedExpression(readingAlias: "r")
        let sql = """
        WITH base AS (
            SELECT r.id, r.timestamp, CAST(r.timestamp / ? AS INTEGER) * ? AS bucket,
                   r.oxygen, r.heart_rate, r.movement, r.status,
                   LAG(r.timestamp) OVER (ORDER BY r.timestamp, r.id) AS previous_timestamp,
                   CASE WHEN r.status IN ('available', 'movement') AND NOT \(movementAffected)
                        THEN 1 ELSE 0 END AS reliable
            FROM readings r WHERE r.timestamp >= ?
        ), grouped AS (
            SELECT *,
                   SUM(CASE WHEN reliable = 1 AND oxygen < 90
                                  AND previous_timestamp IS NOT NULL AND timestamp - previous_timestamp <= ?
                            THEN 0 ELSE 1 END)
                       OVER (PARTITION BY bucket ORDER BY timestamp, id) AS below90_group
            FROM base
        ), stats AS (
            SELECT bucket,
                   AVG(CASE WHEN reliable = 1 THEN oxygen END),
                   MIN(CASE WHEN reliable = 1 THEN oxygen END),
                   MAX(CASE WHEN reliable = 1 THEN oxygen END),
                   AVG(CASE WHEN reliable = 1 THEN heart_rate END),
                   MIN(CASE WHEN reliable = 1 THEN heart_rate END),
                   MAX(CASE WHEN reliable = 1 THEN heart_rate END),
                   AVG(CASE WHEN status IN ('available', 'movement') THEN movement END),
                   SUM(CASE WHEN reliable = 1 AND oxygen < 90 THEN ? ELSE 0 END),
                   SUM(CASE WHEN reliable = 1 THEN 1 ELSE 0 END)
            FROM grouped GROUP BY bucket
        ), runs AS (
            SELECT bucket, below90_group, SUM(?) AS run_seconds
            FROM grouped WHERE reliable = 1 AND oxygen < 90
            GROUP BY bucket, below90_group
        ), longest AS (
            SELECT bucket, MAX(run_seconds) AS longest_seconds FROM runs GROUP BY bucket
        )
        SELECT stats.*, COALESCE(longest.longest_seconds, 0)
        FROM stats LEFT JOIN longest USING (bucket)
        ORDER BY bucket DESC LIMIT ?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(bucketSeconds))
        sqlite3_bind_int(statement, 2, Int32(bucketSeconds))
        sqlite3_bind_double(statement, 3, movementThreshold)
        sqlite3_bind_double(statement, 4, MovementReliability.recovery)
        sqlite3_bind_double(statement, 5, MovementReliability.preRoll)
        sqlite3_bind_double(statement, 6, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, max(10, sampleSeconds * 2.5))
        sqlite3_bind_double(statement, 8, sampleSeconds)
        sqlite3_bind_double(statement, 9, sampleSeconds)
        sqlite3_bind_int(statement, 10, Int32(limit))
        var result: [AggregatedReading] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(AggregatedReading(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                averageOxygen: sqlite3_column_double(statement, 1), minimumOxygen: sqlite3_column_double(statement, 2), maximumOxygen: sqlite3_column_double(statement, 3),
                averageHeartRate: sqlite3_column_double(statement, 4), minimumHeartRate: sqlite3_column_double(statement, 5), maximumHeartRate: sqlite3_column_double(statement, 6),
                averageMovement: optionalDouble(statement, 7),
                below90Duration: sqlite3_column_double(statement, 8),
                longestBelow90Duration: sqlite3_column_double(statement, 10),
                sampleCount: Int(sqlite3_column_int(statement, 9))))
        }
        return result
    }

    static func read(
        databasePath: String,
        since: Date,
        until: Date,
        maximumSampleGap: TimeInterval,
        movementThreshold: Double,
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
        var longestBelow90Duration = 0.0
        var longestBelow88Duration = 0.0
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
        let movementAffected = MovementReliability.sqlAffectedExpression(readingAlias: "span")
        let readingsSQL = """
        WITH ordered AS (
            SELECT id, timestamp, oxygen, heart_rate, status, movement,
                   COALESCE(LEAD(timestamp) OVER (ORDER BY timestamp, id), ?) AS next_timestamp
            FROM readings
            WHERE timestamp >= ? AND timestamp <= ?
        ), spans AS (
            SELECT id, timestamp, oxygen, heart_rate, status, movement,
                   CASE
                       WHEN next_timestamp >= timestamp AND next_timestamp - timestamp <= ?
                       THEN next_timestamp - timestamp
                       ELSE 0
                   END AS seconds
                FROM ordered
        ), classified AS (
            SELECT span.id, span.timestamp, span.oxygen, span.heart_rate, span.status, span.seconds,
                   CASE WHEN span.status IN ('available', 'movement') AND \(movementAffected)
                        THEN 1 ELSE 0 END AS movement_affected
            FROM spans span
        ), grouped AS (
            SELECT *,
                   SUM(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 AND oxygen < 90 AND seconds > 0 THEN 0 ELSE 1 END)
                       OVER (ORDER BY timestamp, id) AS below90_group,
                   SUM(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 AND oxygen < 88 AND seconds > 0 THEN 0 ELSE 1 END)
                       OVER (ORDER BY timestamp, id) AS below88_group
            FROM classified
        )
        SELECT COUNT(*),
               COALESCE(SUM(seconds), 0),
               COALESCE(SUM(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN movement_affected = 1 THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN status IN ('stale', 'unavailable') THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 AND oxygen < 90 THEN seconds ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 AND oxygen < 88 THEN seconds ELSE 0 END), 0),
               AVG(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 THEN oxygen END),
               MIN(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 THEN oxygen END),
               MAX(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 THEN oxygen END),
               AVG(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 THEN heart_rate END),
               MIN(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 THEN heart_rate END),
               MAX(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 THEN heart_rate END),
               COALESCE(SUM(CASE WHEN status IN ('available', 'movement') AND movement_affected = 0 AND (heart_rate < ? OR heart_rate > ?) THEN seconds ELSE 0 END), 0),
               COALESCE((SELECT MAX(run_seconds) FROM (
                   SELECT SUM(seconds) AS run_seconds FROM grouped
                   WHERE status IN ('available', 'movement') AND movement_affected = 0 AND oxygen < 90
                   GROUP BY below90_group
               )), 0),
               COALESCE((SELECT MAX(run_seconds) FROM (
                   SELECT SUM(seconds) AS run_seconds FROM grouped
                   WHERE status IN ('available', 'movement') AND movement_affected = 0 AND oxygen < 88
                   GROUP BY below88_group
               )), 0)
        FROM grouped;
        """
        if sqlite3_prepare_v2(database, readingsSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, until.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, maximumSampleGap)
            sqlite3_bind_double(statement, 5, movementThreshold)
            sqlite3_bind_double(statement, 6, MovementReliability.recovery)
            sqlite3_bind_double(statement, 7, MovementReliability.preRoll)
            sqlite3_bind_double(statement, 8, lowPulseLimit)
            sqlite3_bind_double(statement, 9, highPulseLimit)
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
                longestBelow90Duration = sqlite3_column_double(statement, 14)
                longestBelow88Duration = sqlite3_column_double(statement, 15)
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
            longestBelow90Duration: longestBelow90Duration,
            longestBelow88Duration: longestBelow88Duration,
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
            longestBelow90Duration: 0, longestBelow88Duration: 0,
            averageOxygen: nil, minimumOxygen: nil, maximumOxygen: nil,
            averageHeartRate: nil, minimumHeartRate: nil, maximumHeartRate: nil,
            pulseOutsideLimitsDuration: 0, lowPulseLimit: lowPulseLimit, highPulseLimit: highPulseLimit,
            alarmCount: 0, activeAlarmCount: 0, completedAlarmDuration: 0)
    }
}
