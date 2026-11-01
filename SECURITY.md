# Security Policy

## Privacy by Design

- **All processing is local.** Switchtone reads key events and plays recorded samples entirely on your Mac.
- **No network calls.** The app makes no network requests and has no update check.
- **No typing data stored.** Switchtone reads which key went down or up, never the characters. Nothing is written to disk, and the log carries counters only.
- **No telemetry, no analytics, no accounts.**

## Permissions

| Permission | Why | Scope |
|------------|-----|-------|
| **Input Monitoring** | Hear key presses and releases to play their sounds | A listen-only event tap: key down, key up, modifiers, and left clicks (counted as a signal to warm up the audio output; position and target are never read) |

No other permission is requested. Switchtone does not use the microphone, camera, screen, Accessibility, location, or the network. **Launch at login** uses macOS Login Items through `SMAppService`.

## Stored Data

| Data | Location |
|------|----------|
| Settings | `~/Library/Preferences/info.gabrimatic.switchtone.plist` |
| On/off state for the Control Center control | `~/Library/Application Support/info.gabrimatic.switchtone/state.json` |

Delete both to reset everything (see the Uninstall section of the README).

## Trust Boundaries

| Boundary | Trust Level | Notes |
|----------|-------------|-------|
| Switchtone app and Control Center extension | Trusted | Built from this repository. The extension is sandboxed and may read only the state file |
| Sound samples | Trusted | CC0 and MIT recordings processed by `scripts/make-sounds.swift`, committed to the repository |
| Apple frameworks | System | AVFoundation, CoreGraphics, SwiftUI, AppIntents, WidgetKit |
| MultitouchSupport | System, private | Loaded with `dlopen` from its fixed path under `/System/Library/PrivateFrameworks` for the trackpad tick. The app receives no touch data from it, only opens the actuator and fires it |
| Defaults domain | Local input | Read as plain values; invalid values are replaced with defaults |
| Release downloads | Ad hoc signed | Not notarized; checksums are in `SHA256SUMS.txt` on each release page, and `install.sh` verifies them |

## Verifying a Download

```bash
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
codesign --verify --strict --verbose=2 /Applications/Switchtone.app
```

`install.sh` runs the same checks before it installs anything.

## Supported Versions

Only the latest release receives fixes.

## Vulnerability Reporting

Report vulnerabilities responsibly:

1. **Do not open a public issue.**
2. Use [GitHub's private vulnerability reporting](https://github.com/gabrimatic/switchtone/security/advisories/new) to submit.
3. Include:
   - Steps to reproduce
   - Demonstrated impact
   - Affected version and macOS version
   - Suggested fix (if any)

Expect acknowledgment within 48 hours.
