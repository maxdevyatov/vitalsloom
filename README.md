# VitalsLoom for macOS

A native SwiftUI personal SpO₂ and pulse display with charts, historical analysis, configurable alarms, and local SQLite storage. It can display values supplied by compatible user-owned sock hardware: pulse, SpO₂, battery, signal strength, and movement state.

## Run

Requires macOS 14 or newer and Swift 6.2/Xcode 26 or newer.

Demo mode works without external configuration. Live device access requires service configuration that you are legally authorized to use:

```sh
install -m 600 Configuration/ServiceConfiguration.example.plist Configuration/ServiceConfiguration.plist
```

Fill in the local file with authorized values. `Configuration/ServiceConfiguration.plist` is deliberately ignored by Git. You can alternatively set `VITALSLOOM_SERVICE_CONFIGURATION` to an absolute plist path when running from source.

Packaged apps never embed service credentials. For an installed app, place the configuration at `~/Library/Application Support/VitalsLoom/ServiceConfiguration.plist` with permissions restricted to the current user. Do not commit, publish, or distribute third-party credentials or client secrets.

After filling the ignored local configuration, install it with owner-only permissions using:

```sh
./scripts/install-local-configuration.sh
```

```sh
swift run VitalsLoom
```

With full Xcode 26 selected (the standalone Command Line Tools installation does not include the macOS XCTest framework), run the unit tests with:

```sh
swift test
```

## Package as a macOS app

```sh
./scripts/package-macos-app.sh
```

The optimized, host-architecture, ad-hoc-signed bundle—with its generated monitor icon—is written to `dist/VitalsLoom.app`. It is intended only for local installation on the Mac that built it. A public binary release must instead be built for all supported architectures, signed with an Apple Developer ID using the hardened runtime, notarized, and stapled. Do not distribute an ad-hoc-signed bundle as a trusted release.

The app starts with simulated data. Open **Main Setup**, disable demo mode, select the region for your compatible device account, and enter credentials. Credentials are stored in Keychain; readings stay in the app's local SQLite database. Existing settings and history from the previous bundle are imported transactionally. The legacy database is deliberately retained as a recovery copy and can be removed manually after the imported history has been verified. macOS may request permission to access the legacy Keychain item, and credentials can be entered again if access is unavailable.

API polling and display refresh are jointly configurable down to one second. Every successful poll updates the gauges and appends the chart sample in the same main-thread operation with one local timestamp. **Test minimum changed-value interval** performs a 30-second probe and reports the shortest interval between genuinely changed SpO₂ or pulse values returned by the selected data source.

The native client reads Owlet's movement signal (`mv` on v3 and `MOVEMENT` on v2). Charts shade movement, stale, and unavailable intervals with distinct background colors; those samples are excluded from alarm evaluation and trend aggregation, and chart lines are broken across those gaps. The live Trends panel can switch independently between autoscaled SpO₂ and pulse views.

Alarm rules can be added independently with metric, above/below threshold, sustained duration, and action. **Log only** writes a violation to SQLite; **Log + loud alert** also repeats an in-app alarm sound. The app prevents idle sleep while monitoring and Focus/DND does not suppress in-app audio, but no ordinary macOS app can produce sound while the Mac is manually asleep or override muted hardware/system output.

The **History** page provides raw-refresh, one-minute, and five-minute aggregate tables. **Analysis** summarizes selectable 1-hour, 6-hour, 12-hour, 24-hour, 7-day, and 30-day periods or an exact custom From/To date and time. It includes time below 90% and 88% SpO₂, oxygen and pulse ranges, time outside configured pulse limits, data availability, movement, stale data, and alarm activity. **Alarm Log** shows every triggered threshold violation.

## Safety and license

This project is an unofficial monitor and is not a medical device. It is not intended to diagnose, treat, cure, or prevent any condition, or to replace professional medical advice or a certified medical monitor. Readings, connectivity, storage, charts, and alarms may be delayed, inaccurate, unavailable, or fail completely. Do not rely on this software for diagnosis, treatment, emergency decisions, or situations where failure could cause injury or death. Seek qualified medical care and use an appropriate certified device when medical monitoring is required.

VitalsLoom is provided under the [MIT License](LICENSE), without warranty and subject to its limitation of liability. Third-party attribution and trademark notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

See [PRIVACY.md](PRIVACY.md) for local data handling and [SECURITY.md](SECURITY.md) before reporting a vulnerability. Never attach credentials, device serials, health readings, or database files to a public issue.

VitalsLoom is independent, unofficial software and is not affiliated with, sponsored by, or endorsed by Owlet Baby Care, Inc. Owlet and Dream Sock are trademarks of Owlet Baby Care, Inc. and are mentioned only to identify compatibility. Do not use their logos or imply manufacturer approval.

The compatible-service integration is unofficial, may change or stop working, and may be restricted by applicable service terms. Use it only with hardware and accounts you own or are authorized to access. Obtain appropriate permission and legal review before public or commercial distribution.

The native API implementation was ported from the MIT-licensed [pyowletapi](https://github.com/ryanbdclark/pyowletapi) request flow.
