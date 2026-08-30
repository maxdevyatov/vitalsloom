# Privacy

VitalsLoom does not include analytics, advertising, telemetry, or a developer-operated cloud service.

- Account credentials are stored in the macOS Keychain.
- Recorded readings, device serials, and alarm events are stored locally in
  `~/Library/Application Support/VitalsLoom/readings.sqlite3`.
- Live mode communicates with the endpoints supplied in the user's local
  `ServiceConfiguration.plist`. Data handled by those endpoints is subject to
  the applicable service provider's privacy policy and terms.
- Demo mode does not require a network account.
- Readings and alarm events are retained for 30 days by default. Database,
  write-ahead-log, and service-configuration files are restricted to the
  current macOS user.
- A legacy `~/Library/Application Support/OwletMonitor/readings.sqlite3`
  database is imported once but retained as a recovery copy. After verifying
  the imported history, the user may remove that legacy directory to avoid
  keeping a duplicate of sensitive data.

The local database may contain sensitive health-related information. Use a
strong macOS login password and FileVault, protect backups, and never attach the database, credentials,
device serials, screenshots containing personal data, or diagnostic logs to a
public issue.

Deleting the local database removes VitalsLoom's saved readings and alarm
history. Deleting its Keychain item removes saved account credentials. These
actions do not delete information held by any third-party service.
