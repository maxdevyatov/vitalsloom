import CSQLite
import Foundation

@MainActor
final class HistoryStore {
    private var database: OpaquePointer?
    private(set) var storageError: String?
    let databasePath: String
    private var lastMaintenanceAt = Date.distantPast

    init() {
        let manager = FileManager.default
        let base = (try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? manager.temporaryDirectory
        let legacyDirectory = base.appendingPathComponent("OwletMonitor", isDirectory: true)
        let directory = base.appendingPathComponent("VitalsLoom", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            storageError = "Historical data could not be prepared."
        }
        let path = directory.appendingPathComponent("readings.sqlite3").path
        databasePath = path
        if sqlite3_open(path, &database) == SQLITE_OK {
            if sqlite3_exec(database, "PRAGMA secure_delete=ON;", nil, nil, nil) != SQLITE_OK ||
                sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil) != SQLITE_OK {
                storageError = "Historical database security settings could not be applied."
            }
            sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS readings (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, oxygen REAL NOT NULL, heart_rate REAL NOT NULL, device_serial TEXT NOT NULL);", nil, nil, nil)
            sqlite3_exec(database, "ALTER TABLE readings ADD COLUMN status TEXT NOT NULL DEFAULT 'available';", nil, nil, nil)
            sqlite3_exec(database, "CREATE INDEX IF NOT EXISTS readings_timestamp ON readings(timestamp);", nil, nil, nil)
            sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS alarm_violations (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, rule_name TEXT NOT NULL, metric TEXT NOT NULL, value REAL NOT NULL, threshold REAL NOT NULL, duration REAL NOT NULL, action TEXT NOT NULL, device_serial TEXT NOT NULL);", nil, nil, nil)
            sqlite3_exec(database, "ALTER TABLE alarm_violations ADD COLUMN actual_duration REAL;", nil, nil, nil)
            sqlite3_exec(database, "ALTER TABLE alarm_violations ADD COLUMN ended_at REAL;", nil, nil, nil)
            sqlite3_exec(database, "CREATE INDEX IF NOT EXISTS violations_timestamp ON alarm_violations(timestamp);", nil, nil, nil)
            sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY, completed_at REAL NOT NULL);", nil, nil, nil)
            let requiredReadingColumns: Set<String> = ["timestamp", "oxygen", "heart_rate", "device_serial", "status"]
            let requiredAlarmColumns: Set<String> = ["timestamp", "rule_name", "metric", "value", "threshold", "duration", "action", "device_serial", "actual_duration", "ended_at"]
            if !requiredReadingColumns.isSubset(of: columns(in: "readings", schema: "main")) ||
                !requiredAlarmColumns.isSubset(of: columns(in: "alarm_violations", schema: "main")) {
                storageError = "Historical database schema could not be prepared."
            }
            migrateLegacyDatabase(at: legacyDirectory.appendingPathComponent("readings.sqlite3").path)
            performMaintenanceIfNeeded(force: true)
            sqlite3_exec(database, "UPDATE alarm_violations SET ended_at = timestamp + duration, actual_duration = COALESCE(actual_duration, duration) WHERE ended_at IS NULL;", nil, nil, nil)
            for suffix in ["", "-wal", "-shm"] {
                let file = "\(path)\(suffix)"
                if manager.fileExists(atPath: file) {
                    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
                }
            }
        } else {
            storageError = "Historical database could not be opened."
            if database != nil { sqlite3_close(database); database = nil }
        }
    }

    @discardableResult
    func insert(_ reading: VitalReading) -> VitalReading? {
        guard let database else { recordFailure(); return nil }
        performMaintenanceIfNeeded()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO readings(timestamp, oxygen, heart_rate, device_serial, status) VALUES (?, ?, ?, ?, ?);", -1, &statement, nil) == SQLITE_OK else { recordFailure(); return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, reading.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, reading.oxygenSaturation)
        sqlite3_bind_double(statement, 3, reading.heartRate)
        sqlite3_bind_text(statement, 4, reading.deviceSerial, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 5, reading.status.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { recordFailure(); return nil }
        clearTransientStorageError()
        return VitalReading(id: sqlite3_last_insert_rowid(database), timestamp: reading.timestamp, oxygenSaturation: reading.oxygenSaturation, heartRate: reading.heartRate, deviceSerial: reading.deviceSerial, status: reading.status)
    }

    func readings(since: Date, limit: Int) -> [VitalReading] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT * FROM (SELECT id, timestamp, oxygen, heart_rate, device_serial, status FROM readings WHERE timestamp >= ? ORDER BY timestamp DESC LIMIT ?) ORDER BY timestamp ASC;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var result: [VitalReading] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let serial = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let status = ReadingStatus(rawValue: text(statement, 5)) ?? .available
            result.append(VitalReading(id: sqlite3_column_int64(statement, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), oxygenSaturation: sqlite3_column_double(statement, 2), heartRate: sqlite3_column_double(statement, 3), deviceSerial: serial, status: status))
        }
        return result
    }

    func aggregatedReadings(since: Date, bucketSeconds: Int, limit: Int = 5_000) -> [AggregatedReading] {
        guard let database else { return [] }
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

    func analysis(since: Date, until: Date = .now, maximumSampleGap: TimeInterval, lowPulseLimit: Double, highPulseLimit: Double) -> AnalysisSnapshot {
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

        if let database {
            var statement: OpaquePointer?
            let sql = """
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
            if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK {
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
            let violationSQL = """
            SELECT COUNT(*),
                   COALESCE(SUM(CASE WHEN ended_at IS NULL OR actual_duration IS NULL THEN 0 ELSE
                       actual_duration * MAX(0, MIN(ended_at, ?) - MAX(timestamp, ?)) /
                       MAX(ended_at - timestamp, actual_duration, 0.001) END), 0),
                   COALESCE(SUM(CASE WHEN timestamp <= ? AND (ended_at IS NULL OR ended_at > ?) THEN 1 ELSE 0 END), 0)
            FROM alarm_violations
            WHERE timestamp <= ? AND COALESCE(ended_at, ?) >= ?;
            """
            if sqlite3_prepare_v2(database, violationSQL, -1, &statement, nil) == SQLITE_OK {
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
        }

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

    @discardableResult
    func insertViolation(rule: AlarmRule, value: Double, deviceSerial: String, startedAt timestamp: Date) -> AlarmViolation? {
        guard let database else { recordFailure(); return nil }
        var statement: OpaquePointer?
        let sql = "INSERT INTO alarm_violations(timestamp, rule_name, metric, value, threshold, duration, action, device_serial) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { recordFailure(); return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, timestamp.timeIntervalSince1970)
        bind(rule.name, to: statement, at: 2)
        bind(rule.metric.rawValue, to: statement, at: 3)
        sqlite3_bind_double(statement, 4, value)
        sqlite3_bind_double(statement, 5, rule.threshold)
        sqlite3_bind_double(statement, 6, rule.durationSeconds)
        bind(rule.action.rawValue, to: statement, at: 7)
        bind(deviceSerial, to: statement, at: 8)
        guard sqlite3_step(statement) == SQLITE_DONE else { recordFailure(); return nil }
        clearTransientStorageError()
        return AlarmViolation(id: sqlite3_last_insert_rowid(database), timestamp: timestamp, ruleName: rule.name, metric: rule.metric.rawValue, value: value, threshold: rule.threshold, requiredDurationSeconds: rule.durationSeconds, actualDurationSeconds: nil, endedAt: nil, action: rule.action.rawValue, deviceSerial: deviceSerial)
    }

    func finishViolation(id: Int64, actualDuration: Double, endedAt: Date) {
        guard let database, id > 0 else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE alarm_violations SET actual_duration = ?, ended_at = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { recordFailure(); return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, actualDuration)
        sqlite3_bind_double(statement, 2, endedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        if sqlite3_step(statement) != SQLITE_DONE { recordFailure() } else { clearTransientStorageError() }
    }

    func violations(limit: Int = 2_000) -> [AlarmViolation] {
        guard let database else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT id, timestamp, rule_name, metric, value, threshold, duration, action, device_serial, actual_duration, ended_at FROM alarm_violations ORDER BY timestamp DESC LIMIT ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var result: [AlarmViolation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let actualDuration = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 9)
            let endedAt = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
            result.append(AlarmViolation(id: sqlite3_column_int64(statement, 0), timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), ruleName: text(statement, 2), metric: text(statement, 3), value: sqlite3_column_double(statement, 4), threshold: sqlite3_column_double(statement, 5), requiredDurationSeconds: sqlite3_column_double(statement, 6), actualDurationSeconds: actualDuration, endedAt: endedAt, action: text(statement, 7), deviceSerial: text(statement, 8)))
        }
        return result
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func recordFailure() {
        storageError = "Historical data could not be saved."
    }

    private func clearTransientStorageError() {
        if storageError == "Historical data could not be saved." { storageError = nil }
    }

    private func performMaintenanceIfNeeded(force: Bool = false) {
        guard let database else { return }
        let now = Date.now
        guard force || now.timeIntervalSince(lastMaintenanceAt) >= 3_600 else { return }
        let readingsResult = sqlite3_exec(database, "DELETE FROM readings WHERE timestamp < strftime('%s','now','-30 days');", nil, nil, nil)
        let alarmsResult = sqlite3_exec(database, "DELETE FROM alarm_violations WHERE timestamp < strftime('%s','now','-30 days');", nil, nil, nil)
        if readingsResult == SQLITE_OK, alarmsResult == SQLITE_OK {
            sqlite3_exec(database, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
            lastMaintenanceAt = now
        } else {
            storageError = "Historical data retention could not be applied."
        }
    }

    private func migrateLegacyDatabase(at legacyPath: String) {
        guard let database, FileManager.default.fileExists(atPath: legacyPath) else { return }
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM migrations WHERE name = 'OwletMonitor-v1';", -1, &check, nil) == SQLITE_OK else { return }
        let alreadyMigrated = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        if alreadyMigrated { return }

        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(database, "ATTACH DATABASE ? AS legacy;", -1, &attach, nil) == SQLITE_OK else { recordFailure(); return }
        sqlite3_bind_text(attach, 1, legacyPath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let attached = sqlite3_step(attach) == SQLITE_DONE
        sqlite3_finalize(attach)
        guard attached else { recordFailure(); return }
        defer { sqlite3_exec(database, "DETACH DATABASE legacy;", nil, nil, nil) }

        let readingColumns = columns(in: "readings", schema: "legacy")
        guard readingColumns.contains("timestamp"), readingColumns.contains("oxygen"),
              readingColumns.contains("heart_rate"), readingColumns.contains("device_serial") else { return }
        let statusExpression = readingColumns.contains("status") ? "status" : "'available'"
        let readingSQL = "INSERT INTO readings(timestamp, oxygen, heart_rate, device_serial, status) SELECT timestamp, oxygen, heart_rate, device_serial, \(statusExpression) FROM legacy.readings;"

        guard sqlite3_exec(database, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { recordFailure(); return }
        var succeeded = sqlite3_exec(database, readingSQL, nil, nil, nil) == SQLITE_OK
        let alarmColumns = columns(in: "alarm_violations", schema: "legacy")
        if succeeded, !alarmColumns.isEmpty {
            let required = ["timestamp", "rule_name", "metric", "value", "threshold", "duration", "action", "device_serial"]
            if required.allSatisfy(alarmColumns.contains) {
                let actual = alarmColumns.contains("actual_duration") ? "actual_duration" : "NULL"
                let ended = alarmColumns.contains("ended_at") ? "ended_at" : "NULL"
                let alarmSQL = "INSERT INTO alarm_violations(timestamp, rule_name, metric, value, threshold, duration, action, device_serial, actual_duration, ended_at) SELECT timestamp, rule_name, metric, value, threshold, duration, action, device_serial, \(actual), \(ended) FROM legacy.alarm_violations;"
                succeeded = sqlite3_exec(database, alarmSQL, nil, nil, nil) == SQLITE_OK
            }
        }
        if succeeded {
            succeeded = sqlite3_exec(database, "INSERT INTO migrations(name, completed_at) VALUES ('OwletMonitor-v1', strftime('%s','now'));", nil, nil, nil) == SQLITE_OK
        }
        if succeeded { succeeded = sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK }
        if !succeeded {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            recordFailure()
        }
    }

    private func columns(in table: String, schema: String) -> Set<String> {
        guard let database else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(schema).table_info(\(table));", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { result.insert(text(statement, 1)) }
        return result
    }
}
