import Darwin
import Foundation

enum OwletAPIError: LocalizedError {
    case invalidCredentials
    case noDevices
    case noLiveReading
    case missingServiceConfiguration
    case invalidServiceConfiguration
    case invalidResponse(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Invalid device-account email or password."
        case .noDevices: "No supported socks were found."
        case .noLiveReading: "The sock is not currently reporting a usable reading."
        case .missingServiceConfiguration: "Unofficial service configuration is missing. See the repository README."
        case .invalidServiceConfiguration: "Unofficial service configuration is invalid or has unsafe file permissions."
        case .invalidResponse(let detail): "The device service returned an unexpected response: \(detail)"
        case .server(let code): "The device service returned HTTP \(code)."
        }
    }
}

private final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor OwletAPI {
    struct Device: Sendable { let serial: String; let name: String }

    private struct RegionInfo: Decodable {
        let mini, signIn, base, apiKey, appID, appSecret, androidPackage, androidCertificate: String
    }

    private let credentials: OwletCredentials
    private let session: URLSession
    private var accessToken: String?
    private var refreshToken: String?
    private var expiry = Date.distantPast

    init(credentials: OwletCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration, delegate: RejectRedirectDelegate(), delegateQueue: nil)
        }
    }

    func authenticate() async throws {
        let info = try regionInfo()
        guard var components = URLComponents(string: "https://www.googleapis.com/identitytoolkit/v3/relyingparty/verifyPassword") else {
            throw OwletAPIError.invalidServiceConfiguration
        }
        components.queryItems = [URLQueryItem(name: "key", value: info.apiKey)]
        guard let url = components.url else { throw OwletAPIError.invalidServiceConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(info.androidPackage, forHTTPHeaderField: "X-Android-Package")
        request.setValue(info.androidCertificate, forHTTPHeaderField: "X-Android-Cert")
        request.httpBody = form(["email": credentials.email, "password": credentials.password, "returnSecureToken": "true"])
        let response = try await send(request)
        guard let refresh = response["refreshToken"] as? String, !refresh.isEmpty else { throw OwletAPIError.invalidCredentials }
        refreshToken = refresh
        try await refreshAuthentication()
    }

    func devices() async throws -> [Device] {
        let json = try await authorizedRequest(path: "/devices.json")
        guard let items = json as? [[String: Any]] else { throw OwletAPIError.invalidResponse("device list") }
        let devices = items.compactMap { item -> Device? in
            guard let device = item["device"] as? [String: Any],
                  let dsn = device["dsn"] as? String,
                  !dsn.isEmpty,
                  dsn.count <= 128 else { return nil }
            return Device(serial: dsn, name: device["product_name"] as? String ?? "Compatible Sock")
        }
        guard !devices.isEmpty else { throw OwletAPIError.noDevices }
        return devices
    }

    func vitals(for device: Device) async throws -> LiveVitals {
        let active: [String: Any] = ["datapoint": ["metadata": [:], "value": 1]]
        var pathSegmentCharacters = CharacterSet.alphanumerics
        pathSegmentCharacters.insert(charactersIn: "-._~")
        guard let serial = device.serial.addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) else {
            throw OwletAPIError.invalidResponse("device identifier")
        }
        _ = try await authorizedRequest(path: "/dsns/\(serial)/properties/APP_ACTIVE/datapoints.json", method: "POST", body: active)
        let json = try await authorizedRequest(path: "/dsns/\(serial)/properties.json")
        guard let items = json as? [[String: Any]] else { throw OwletAPIError.invalidResponse("property list") }
        var properties: [String: [String: Any]] = [:]
        for item in items {
            if let property = item["property"] as? [String: Any], let name = property["name"] as? String { properties[name] = property }
        }

        if let value = properties["REAL_TIME_VITALS"]?["value"] as? String,
           let data = value.data(using: .utf8),
           let realtime = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if numericValue(realtime["ox"]) == 0 || numericValue(realtime["hr"]) == 0 {
                throw OwletAPIError.noLiveReading
            }
            let oxygen = try requiredNumber(realtime["ox"], named: "oxygen", allowed: 1...100)
            let heartRate = try requiredNumber(realtime["hr"], named: "heart rate", allowed: 20...350)
            return LiveVitals(
                oxygenSaturation: oxygen,
                heartRate: heartRate,
                batteryPercentage: optionalNumber(realtime["bat"], allowed: 0...100),
                signalStrength: optionalNumber(realtime["rsi"], allowed: -150...0),
                timestamp: parseDate(properties["REAL_TIME_VITALS"]?["data_updated_at"]) ?? .distantPast,
                serial: device.serial,
                // Dream Sock/v3 exposes `mv` as a numeric magnitude. Preserve
                // it for history without interpreting it as a boolean event.
                movement: safeInteger(realtime["mv"], allowed: 0...1_000))
        }

        if numericValue(properties["OXYGEN_LEVEL"]?["value"]) == 0 || numericValue(properties["HEART_RATE"]?["value"]) == 0 {
            throw OwletAPIError.noLiveReading
        }
        let oxygen = try requiredPropertyNumber("OXYGEN_LEVEL", in: properties, named: "oxygen", allowed: 1...100)
        let heartRate = try requiredPropertyNumber("HEART_RATE", in: properties, named: "heart rate", allowed: 20...350)
        let oxygenTimestamp = parseDate(properties["OXYGEN_LEVEL"]?["data_updated_at"])
        let heartRateTimestamp = parseDate(properties["HEART_RATE"]?["data_updated_at"])
        let sourceTimestamp = max(oxygenTimestamp ?? .distantPast, heartRateTimestamp ?? .distantPast)
        return LiveVitals(
            oxygenSaturation: oxygen,
            heartRate: heartRate,
            batteryPercentage: optionalPropertyNumber("BATT_LEVEL", in: properties, allowed: 0...100),
            signalStrength: optionalPropertyNumber("BLE_RSSI", in: properties, allowed: -150...0),
            timestamp: sourceTimestamp,
            serial: device.serial,
            movement: safeInteger(properties["MOVEMENT"]?["value"], allowed: 0...1_000),
            reportsMovementAsBoolean: true)
    }

    private func refreshAuthentication() async throws {
        guard let refreshToken else { throw OwletAPIError.invalidCredentials }
        let info = try regionInfo()
        guard var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token") else {
            throw OwletAPIError.invalidServiceConfiguration
        }
        components.queryItems = [URLQueryItem(name: "key", value: info.apiKey)]
        guard let refreshURL = components.url else { throw OwletAPIError.invalidServiceConfiguration }
        var refreshRequest = URLRequest(url: refreshURL)
        refreshRequest.httpMethod = "POST"
        refreshRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        refreshRequest.setValue(info.androidPackage, forHTTPHeaderField: "X-Android-Package")
        refreshRequest.setValue(info.androidCertificate, forHTTPHeaderField: "X-Android-Cert")
        refreshRequest.httpBody = form(["grantType": "refresh_token", "refreshToken": refreshToken])
        let refreshed = try await send(refreshRequest)
        self.refreshToken = refreshed["refresh_token"] as? String ?? refreshToken
        guard let idToken = refreshed["id_token"] as? String, !idToken.isEmpty else { throw OwletAPIError.invalidResponse("identity token") }

        var miniRequest = URLRequest(url: try validatedURL(info.mini, expectedHost: expectedHosts.mini))
        miniRequest.setValue(idToken, forHTTPHeaderField: "Authorization")
        let mini = try await send(miniRequest)
        guard let miniToken = mini["mini_token"] as? String, !miniToken.isEmpty else { throw OwletAPIError.invalidResponse("mini token") }

        var signIn = URLRequest(url: try validatedURL(info.signIn, expectedHost: expectedHosts.signIn))
        signIn.httpMethod = "POST"
        signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signIn.setValue("application/json", forHTTPHeaderField: "Accept")
        signIn.httpBody = try JSONSerialization.data(withJSONObject: ["app_id": info.appID, "app_secret": info.appSecret, "provider": "owl_id", "token": miniToken])
        let signedIn = try await send(signIn)
        guard let token = signedIn["access_token"] as? String, !token.isEmpty else { throw OwletAPIError.invalidResponse("access token") }
        accessToken = token
        expiry = .now.addingTimeInterval((optionalNumber(signedIn["expires_in"], allowed: 1...86_400) ?? 3_600) - 60)
    }

    private func authorizedRequest(path: String, method: String = "GET", body: [String: Any]? = nil, didRetryAuthentication: Bool = false) async throws -> Any {
        if accessToken == nil || expiry <= .now { try await refreshAuthentication() }
        let info = try regionInfo()
        _ = try validatedURL(info.base, expectedHost: expectedHosts.base)
        let url = try validatedURL(info.base + path, expectedHost: expectedHosts.base)
        var request = URLRequest(url: url)
        request.httpMethod = method
        guard let token = accessToken else { throw OwletAPIError.invalidCredentials }
        request.setValue("auth_token \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OwletAPIError.invalidResponse("HTTP response") }
        if http.statusCode == 401, !didRetryAuthentication {
            accessToken = nil
            try await refreshAuthentication()
            return try await authorizedRequest(path: path, method: method, body: body, didRetryAuthentication: true)
        }
        guard (200...201).contains(http.statusCode) else { throw OwletAPIError.server(http.statusCode) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OwletAPIError.invalidResponse("HTTP response") }
        guard (200...201).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 { throw OwletAPIError.invalidCredentials }
            throw OwletAPIError.server(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OwletAPIError.invalidResponse("JSON body")
        }
        return json
    }

    private func regionInfo() throws -> RegionInfo {
        let key = credentials.region == .world ? "World" : "Europe"
        let configuration = try Self.loadServiceConfiguration()
        guard let info = configuration[key] else { throw OwletAPIError.missingServiceConfiguration }
        _ = try validatedURL(info.mini, expectedHost: expectedHosts.mini)
        _ = try validatedURL(info.signIn, expectedHost: expectedHosts.signIn)
        _ = try validatedURL(info.base, expectedHost: expectedHosts.base)
        let secrets = [info.apiKey, info.appID, info.appSecret, info.androidPackage, info.androidCertificate]
        guard secrets.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("REPLACE_") }) else {
            throw OwletAPIError.invalidServiceConfiguration
        }
        return info
    }

    private var expectedHosts: (mini: String, signIn: String, base: String) {
        switch credentials.region {
        case .world:
            ("ayla-sso.owletdata.com", "user-field-1a2039d9.aylanetworks.com", "ads-field-1a2039d9.aylanetworks.com")
        case .europe:
            ("ayla-sso.eu.owletdata.com", "user-field-eu-1a2039d9.aylanetworks.com", "ads-field-eu-1a2039d9.aylanetworks.com")
        }
    }

    private func validatedURL(_ string: String, expectedHost: String) throws -> URL {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == expectedHost,
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else { throw OwletAPIError.invalidServiceConfiguration }
        return url
    }

    private static func loadServiceConfiguration() throws -> [String: RegionInfo] {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["VITALSLOOM_SERVICE_CONFIGURATION"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false) {
            candidates.append(applicationSupport.appendingPathComponent("VitalsLoom/ServiceConfiguration.plist"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Configuration/ServiceConfiguration.plist"))

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == geteuid(),
                  (status.st_mode & 0o077) == 0 else { throw OwletAPIError.invalidServiceConfiguration }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return try PropertyListDecoder().decode([String: RegionInfo].self, from: data)
            } catch {
                throw OwletAPIError.invalidServiceConfiguration
            }
        }
        throw OwletAPIError.missingServiceConfiguration
    }

    private func form(_ fields: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let safeValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(safeKey)=\(safeValue)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }

    private func rawNumber(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber { result = number.doubleValue }
        else if let string = value as? String { result = Double(string) }
        else { result = nil }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private func requiredNumber(_ value: Any?, named name: String, allowed: ClosedRange<Double>) throws -> Double {
        guard let number = rawNumber(value), allowed.contains(number) else {
            throw OwletAPIError.invalidResponse("invalid \(name)")
        }
        return number
    }

    private func numericValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func optionalNumber(_ value: Any?, allowed: ClosedRange<Double>) -> Double? {
        guard let number = rawNumber(value), allowed.contains(number) else { return nil }
        return number
    }

    private func requiredPropertyNumber(_ key: String, in properties: [String: [String: Any]], named name: String, allowed: ClosedRange<Double>) throws -> Double {
        try requiredNumber(properties[key]?["value"], named: name, allowed: allowed)
    }

    private func optionalPropertyNumber(_ key: String, in properties: [String: [String: Any]], allowed: ClosedRange<Double>) -> Double? {
        optionalNumber(properties[key]?["value"], allowed: allowed)
    }

    private func safeInteger(_ value: Any?, allowed: ClosedRange<Double>) -> Int? {
        guard let number = rawNumber(value), allowed.contains(number) else { return nil }
        return Int(number.rounded(.towardZero))
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        guard let date = ISO8601DateFormatter().date(from: string),
              date >= Date(timeIntervalSince1970: 1_577_836_800),
              date <= Date.now.addingTimeInterval(300) else { return nil }
        return date
    }
}
