# Contributing

Bug reports, ideas and pull requests are welcome.

## Dev Setup

Requirements: macOS 26 or later on Apple silicon, and Xcode 27 or later (Swift 6).

```bash
git clone https://github.com/gabrimatic/switchtone.git
cd switchtone
./build.sh --install
```

Switchtone has no Xcode project and no package dependencies: `build.sh` compiles with `swiftc`.

Builds are signed ad hoc, so macOS can ask for permissions again after a rebuild. To keep your grants, create a self-signed code signing certificate and build with `SWITCHTONE_SIGN_IDENTITY="My Local Signing" ./build.sh --install`.

## Project Structure

```
switchtone/
├── .github/                 # Issue and PR templates
├── Sources/Switchtone/      # The app: key tap, sound engine, 3D scene, panel, windows, intents
├── Sources/Shared/          # Code shared with the Control Center extension
├── Extensions/SwitchtoneControls/  # The Control Center control
├── Resources/               # Info.plist, the sound samples and their notice, typeface
├── scripts/                 # package.sh, make-sounds.swift, make-icon.swift
├── docs/                    # SPEC.md, PLATFORM.md, DESIGN.md, the website
├── assets/                  # README images
├── build.sh                 # Build and install
├── install.sh               # One-line installer for releases
├── README.md
├── LICENSE
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
└── SECURITY.md
```

[docs/SPEC.md](docs/SPEC.md) states what must be true; if the README or the code disagree with it, fix them to match, or change the spec in the same pull request.

## Code Style

- Swift 6 with strict concurrency; keep the build free of new warnings.
- Follow [docs/DESIGN.md](docs/DESIGN.md): the ink, ice and accent palette, IBM Plex Sans, SF Symbols as plain line icons, no gradients. Glass only on things you click, and never stacked on glass.
- The key-event path takes no locks and does no allocation. Read section 3 of [docs/SPEC.md](docs/SPEC.md) before you touch it.
- Switchtone never reads or logs what is typed, only which key went down or up. Keep it that way.
- Sound files come only from CC0 or MIT sources, with the source recorded in the README and any licence notice in `Resources/Sounds/NOTICE.txt`.
- No network access, no analytics and no new dependency. A new permission needs a reason in the pull request.
- Respect Reduce Motion, Reduce Transparency and Increase Contrast, and give every control a VoiceOver label.

## PR Checklist

- `./build.sh` succeeds
- The change was tried on a real Mac in the running app if the key path, audio or a window changed
- Light and dark appearance checked for visual changes, with a screenshot or clip in the pull request
- README and `docs/SPEC.md` updated if behavior changed
- No typing data read, stored or logged
- No credentials or personal data in any file
- The pull request says what changed and why

## Reporting Issues

Include:

- Switchtone version (Settings > About)
- macOS version and Mac model
- The output device (built-in speakers, headphones, AirPods)
- Steps to reproduce
- What you expected vs. what happened
- Relevant lines from `log show --last 5m --predicate 'subsystem == "info.gabrimatic.switchtone"' --info`

## Releases

1. Set `CFBundleShortVersionString` and raise `CFBundleVersion` in `Resources/Info.plist` and `Extensions/SwitchtoneControls/Info.plist`.
2. Run `scripts/package.sh` and look at `dist/`. It builds from a clean tree, signs ad hoc, writes `Switchtone-X.Y.Z.zip`, `Switchtone-X.Y.Z.dmg` and `SHA256SUMS.txt`, and checks what it wrote.
3. Tag `vX.Y.Z`, push the tag, and attach the three files to a GitHub release of that tag.

Do not add a signing identity or credentials to the repository.

## Security

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/gabrimatic/switchtone/security/advisories/new), not public issues. Details: [SECURITY.md](SECURITY.md).
