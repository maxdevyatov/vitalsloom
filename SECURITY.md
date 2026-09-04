# Security Policy

## Reporting a vulnerability

Please use a private GitHub Security Advisory after the repository is
published. Do not disclose an unpatched vulnerability in a public issue.

Do not include account credentials, service configuration, access tokens,
device serials, health readings, database files, or other personal information
in a report. Use demo data and redact request and response bodies whenever
possible.

Service configuration must remain outside distributable application bundles.
The packaging script intentionally does not copy it into the app.
Configuration files must be owned by the current user and have mode `0600`;
the client rejects broader permissions and only permits the known HTTPS hosts
for the selected service region. Never replace those checks with arbitrary
user-configured bearer-token destinations.

Preview builds may be distributed with an ad-hoc signature only when they are
clearly labeled as unsigned and unnotarized and accompanied by a published
SHA-256 checksum. A trusted public release requires an Apple Developer ID,
hardened runtime, universal architecture support, and Apple
notarization/stapling.

## Scope and limitations

VitalsLoom is independent, unofficial software and is not a medical device.
It must not be used for safety-critical or medical decision-making. A security
reporting process does not imply any warranty, support commitment, or fitness
for a particular purpose; the MIT License applies.
