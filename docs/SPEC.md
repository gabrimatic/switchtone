# Switchtone specification

Single source of truth. README and PLATFORM.md describe what ships; this file says what must be true. A change that breaks a line here is a bug, or this file changes first.

Target: macOS 26 and later, Apple silicon, Xcode 27 or later (Swift 6). Bundle id `info.gabrimatic.switchtone`. Free, native Swift, menu bar only (`LSUIElement`, no Dock icon in any state).

## 1. Sound

1. Real recorded samples only, from lossless sources under CC0 or MIT, credited in the README, with the license notice shipped next to them. 48 kHz, 24-bit stereo, a real low end around 120 to 300 Hz, and the hit within 2.5 ms of the sample's start. Three profiles: Linear (creamy), Tactile (thocky, default), Clicky (crisp). Press on key down, release on key up, for every key in every app.
2. Hold a key: silent after the first press (no auto-repeat sound). A release with no press heard is silent.
3. Per-key tuning, random sample and pitch variation per press.
4. Speed dynamics, continuous: a slow press lands hard (full level, bright, rings out over about 80 ms); at full speed, about 110 words a minute, a key is half as loud, darker and rings out in half the time. Each strike varies slightly in length.
5. Natural key-up timing: release plays 6 to 13 ms after the key-up event, never closer than 22 ms to its own press, scheduled on the host clock. Its level falls with typing speed but it never stops.
6. Strikes are independent: nothing cuts one off, each sounds from its own key, and they overlap freely. Each rings out on an exponential decay to -40 dB, and a new strike makes equal-power room for what is still ringing, so a flurry never piles up.
6a. Depth: every recording plays 7% slower, like a heavier cap, and each strike excites a case resonance on its own low note (105 to 175 Hz, long keys lowest). The harder the touch, the more the case rings; fast keys and releases barely move it.
7. Stabilizer character on big keys (Space, Return, Delete, Shift): short metallic ticks after the hit, hit itself untouched.
8. Volume 0 plays nothing and lets the output sleep; the panel says Muted.

## 2. True 3D sound

1. Every key has its place on a MacBook ANSI layout, from its column and row. The middle of the image is where the hands meet, between F and J: the home row is a mirror image around it, and the keys at the edges (the key left of 1, Delete) sit equally far out. Other layouts play correctly with approximate positions.
2. Headphones and AirPods: `AVAudioEnvironmentNode`, each key a point source about 30 cm below and 40 cm in front of the ears, `HRTFHQ`, `outputType = .headphones`. Edge keys about 36 degrees out. Under Low Power Mode or serious/critical thermal state: plain `HRTF`. If the output offers no HRTF, the stereo stage.
3. Speakers (built-in and external): the stereo stage. Each voice has an equal-power gain per channel and a short inter-channel delay, the near channel first: 12 dB and 0.35 ms at the edge by design, with a curve that opens up the middle of the board. Mirror-image keys differ by under 1.25 dB. The environment node is out of the graph. With 3D off: plain stereo, 4.5 dB at the edge, no delay.
4. Head tracking on supporting AirPods/Beats: `listenerHeadTrackingEnabled`, switchable in the panel (Follow head movement, shown only on headphones with 3D on). Decision on record: `CMHeadphoneMotionManager` is not used because the engine's own tracking needs no motion permission or update loop; if a device needs it, reopen the decision here first.
5. Dry on every path: no reverb, nothing rings past the strike.
6. Near and far rows differ by about 1 dB on both paths.
7. Route changes (headphones in/out, default device, jack data source) re-pick the rendering live and restart output. Bluetooth counts as headphones unless the name marks a speaker (speaker, soundbar, HomePod, TV and the like).
8. 3D off means plain stereo, no environment cost, spatial data never loaded. The same holds for speakers: the HRTF data loads only when headphones first play.

## 3. Latency and real-time safety

1. 64-frame output buffer (1.3 ms at 48 kHz). What Switchtone controls, from the tap callback to the sample leaving for the device, stays under 10 ms with a target of about 2 ms. The output device's own path comes on top and is reported as read from Core Audio (`OutputPath`): device latency, stream latency and safety offset, never `presentationLatency` alone. On the built-in speakers that is 16.6 ms and no app can shorten it. The counters report the delay from the key event's timestamp to the tap callback as median, 95th percentile, average and maximum, and the first key after five quiet seconds on its own: the median is the figure that judges Switchtone, because one press delayed by a busy Mac or a waking core moves the average and the maximum but not the median.
2. Every sample starts on its hit: no finger noise ahead of the bottom-out, and leading silence trimmed at load.
3. No lock, allocation, system RNG, or main-thread/hardware wait on the event-tap thread. Settings are atomics; the bank is an atomically swapped pointer; the tap thread owns its voices' bookkeeping and reaches the render thread through a single-producer ring. The render thread takes no lock and allocates nothing.
4. Previews and wake presses play on their own voices; hover-out never cuts off typing.
5. After the output pauses, the first press restarts it and plays if ready within 120 ms; wake and unlock warm the output ahead of the first key. A left click warms it only within two minutes of the last key and never in Low Power Mode or under thermal pressure; a scroll never does; turning Switchtone on warms it only when sounds are audible (on, allowed, not muted by a Focus, volume above 0).
6. The main thread never waits for the permission preflight (about 10 ms): it runs off the main thread everywhere. Opening the panel holds the main thread for less than one 120 Hz frame (8.3 ms).

## 4. Panel (SwiftUI)

1. `NSPopover` from the menu bar symbol. Click opens; Option-click toggles sounds with a haptic and no panel. Launching Switchtone again (Finder, `open`, Spotlight, a second launch) shows the welcome window until it is finished and the Settings window after that, never the panel, so nothing depends on the symbol; the panel has a Settings button. The log records where the symbol ended up (`menu bar symbol: ... onScreen=`); `onScreen=false` is the intended state when the person has turned the icon off.
2. Header: app name, state line, master Sounds switch. The state line uses one word per state and the same words as the notice below it: "On · Tactile", "Off", "Not listening" (no permission), "Paused" (a Focus, notice "Paused by your Focus"), "No sound" (no output, notice "No sound"), "Muted" (volume 0).
3. Three profile cards in one `GlassEffectContainer`, interactive glass, selected card washed in the accent with a hairline and check mark that hand over between cards without overlapping (keyboard focus is only a thin neutral outline outside the card, shown while navigating by keyboard and never after a click, so it cannot read as a second selection), the mark's keycap with a wave that tells the profile's character (the wave takes the accent when selected or playing), hover plays a short live preview phrase; choosing a profile decodes in the background.
4. Volume slider with variable-value symbol and percentage; haptic at 0 and 100.
5. 3D sound toggle with the current output named ("Off · plain stereo" when off); Follow head movement row (headphones, 3D on).
6. Mute when typing passwords (default on): silent while macOS secure keyboard entry is on, modifiers included.
7. Launch at login (ServiceManagement) with states: enabled, needs approval (link to Login Items), error in plain language.
8. On/off global shortcut Control-Option-Command-K, shown in the panel and honored in any app.
9. Quit; Command-Q works while the panel is open. Escape closes. The panel makes Switchtone active while open so controls draw active and Tab navigates; the previous app regains the keyboard on close.
10. One notice at a time, most basic first: permission, then sound output, then Focus. Notices open downward with the rows below.
11. Concentric radii (`ConcentricRectangle`), IBM Plex Sans and line SF Symbols per docs/DESIGN.md, SwiftUI springs at the display rate (120 Hz), no glass on glass beyond the cards. Switches are neutral: the accent stays on the one selected card and the one active bar.
12. Perfect light and dark. Fixed content and reading order; nothing clipped at any state.

## 5. Input Monitoring UX

1. The welcome window's "Allow…" button, or the first need for the permission, shows the system prompt, which macOS shows once. After that: the button reads "Open System Settings", and the panel shows the notice "Allow Input Monitoring" with an "Allow in Settings" button. Both open Privacy & Security > Input Monitoring.
2. Menu bar symbol shows the attention state while not allowed; a revoked grant shows at once (also on wake and panel open).
3. Recovers live: grant noticed within about 1 s, tap starts, "Switchtone can hear your keys" confirms, no relaunch, haptic.
4. Stale grant (listed but deaf): relaunch once automatically (at most once per 10 minutes, and on return from System Settings), then the notice "Switch Switchtone off and on in Input Monitoring".
5. Polling cost while waiting: one check per app switch, every 1 s while System Settings is frontmost or a Switchtone window is open, otherwise every 20 s.
6. Never stores, logs or sends what is typed; the log carries counters only.

## 6. System integration

1. App Intents: Toggle Switchtone Sounds, Turn Switchtone Sounds Off ("Mute Switchtone"), Turn Switchtone Sounds On ("Unmute Switchtone"), Set Switchtone Switches, Set Switchtone Volume; Siri phrases via App Shortcuts. Fixed-state intents set, never toggle. Set Switchtone Sounds (on or off) is hidden from the Shortcuts library.
2. Focus filter mutes while a chosen Focus is on; the panel says so.
3. Control Center / menu bar `ControlWidgetToggle` in a sandboxed WidgetKit extension showing on/off (state file in `~/Library/Application Support/info.gabrimatic.switchtone/`); shows off after Switchtone quits, including after SIGTERM.
4. Login item through `SMAppService` only. No launchd agents, no cron.
5. Every setting is written to the `info.gabrimatic.switchtone` defaults domain on first launch and on each change, so `defaults read` shows the real state. The domain is the store: a write from outside the app (`defaults write`, a script) is adopted live (panel, sounds, tap), a deleted or invalid value is written back as the default; `state.json` only tells the control whether Switchtone is running with its sounds on.
6. Haptics: slider ends, profile choice, Option-click, permission arrival.

## 7. Accessibility

1. VoiceOver label, value and hint on every control (the Settings switches and the welcome window's Launch at login switch and Done button carry their own labels, and Show Again reads "Show welcome window again"); cards are selectable buttons with "title, character"; notices read as one element; switches keep on/off value.
2. Reduce Motion: no hover growth; changes cross-fade.
3. Reduce Transparency: solid card surfaces. Increase Contrast: borders added.
4. Full Keyboard Access: Tab order follows reading order.

## 8. Resource budget

1. Idle (output paused): about 0% CPU, one listen-only event tap, no timers once the first two minutes after launch have passed and Input Monitoring is allowed. While the output runs, one 10 s check decides when to pause it.
2. Output running: about 1 to 2% of one core. Pause after one quiet minute; at volume 0 never starts.
3. RAM, as the physical footprint (`footprint -p`, Activity Monitor's figure; `ps` rss also counts pages the system has freed but not taken back and runs 20 to 80 MB higher): about 25 MB on the speakers with the output running, about 3 MB of it per sample bank; the HRTF data comes on top on headphones; SwiftUI's own data adds about 30 MB once the panel or a window has opened, and the system keeps it. Switching profiles must not grow it: the old bank is released two seconds after the swap and its pages are returned at once.
4. No crashes, no console errors from `info.gabrimatic.switchtone` at default log level.

## 9. Security and privacy

1. Listen-only event tap; only the key code is read, never characters. The tap also receives left clicks, counted only as a signal to warm the output (no position, no target); scrolls are not received. No network access, no analytics, no files with typing data.
2. Secure keyboard entry silences everything when Mute when typing passwords is on.
3. Sandboxed extension, read-only exception for the state file only. Hardened runtime signing. Release builds are ad hoc signed; a local build signed with a stable self-signed identity (`SWITCHTONE_SIGN_IDENTITY`) keeps the Input Monitoring grant across rebuilds.
4. No secrets and no hardcoded credentials. No names of other apps in code, UI or docs (the sound authors are credited in the README).
5. One private framework, `MultitouchSupport`, loaded with `dlopen` behind a capability check for the trackpad tick. Nothing else private, nothing linked against it.

## 10. Trackpad tick

1. A tap on the trackpad on every press that plays a sound, never on a release or an auto-repeat, and only while the gate is open (sounds on, allowed, not muted by a Focus, volume above 0, not in secure entry).
2. Settings > Sounds > Trackpad tick, on by default (`trackpadTick` in the defaults domain), adopted live from outside the app. Without an actuator the row says "Needs a Force Touch trackpad" and is disabled.
3. Through `MTActuatorCreateFromDeviceID`, `MTActuatorOpen` and `MTActuatorActuate`, resolved at run time. The capability check is every symbol resolving, a device existing and its actuator opening, and it runs off the main thread. Anything missing means no tick and no error, ever.
4. An actuation takes about 4 ms, so it never runs on the event-tap thread: the tap raises a flag and a thread of its own does the rest. Presses during a tick fold into one. The actuator is closed after 30 quiet seconds, reopened on the next press, and given up on silently after five failures in a row.

## 11. Out of scope

Custom sound packs, per-app rules, non-Apple-silicon, macOS before 26, desktop widgets, notifications, Metal shaders.

## Menu bar icon

Settings > General has Show menu bar icon, on by default (`showMenuBarIcon` in the defaults domain). Turning it off removes the status item at once and the app keeps running; a launch with it off never creates the item, so it takes no room in the bar, for example next to the notch. A `defaults write` is adopted live. People can also hide the icon in System Settings > Menu Bar > Allow in the Menu Bar. Both are supported states: with the setting off the log says `menu bar symbol: off in Settings, no status item`, with the system hiding it `onScreen=false`. The app must work fully without its icon: opening the app again from Finder or Spotlight shows its Settings window, and every function stays reachable there. Switchtone never asks for the icon to be turned back on.

## A complete, first-class macOS app

Switchtone must feel like a polished Mac app, not a tool. Every item below is required:

1. **First-run onboarding:** a calm welcome window on the flat ground on first launch. It says in one line what the app does, then shows the one permission the app needs, Input Monitoring, in one row with:
   - an "Allow…" button that triggers the real macOS system prompt (`CGRequestListenEventAccess`), so macOS itself adds the app to the list and asks. You never have to press "+" in System Settings.
   - a live status that reads "Allowed" the moment access is granted, with no relaunch.
   - a fallback "Open System Settings" button to the exact pane, only if the prompt was already denied.
   Then a "Launch at login" switch, on from the first launch, and a Done button. Done, Esc and the close button end the window the same way, and it never returns on its own: Settings > Permissions > Welcome window > "Show Again" brings it back. Never pre-set the onboarding flag to skip it.
2. **Ask at first need too:** if a feature needs a permission that isn't granted, ask with the system prompt at that moment, then show a clear "Not allowed yet" state with one button. Never fail silently.
3. **Info.plist completeness:** CFBundleDisplayName, a version and build, NSHumanReadableCopyright "© 2026 Soroush Yousefpour", LSApplicationCategoryType, LSUIElement and the app icon. Input Monitoring takes no usage-description string.
4. **Reopen behavior:** opening the app again from Finder or Spotlight while it runs shows the welcome window until it is finished, and its Settings window after that (`applicationShouldHandleReopen`). The menu bar icon may be hidden (Show menu bar icon off, or hidden by the system), and everything must stay reachable without it.
5. **Standard menus while a window is in front:** App menu with About Switchtone (a custom About window with icon, version, one-line description and copyright), Settings… ⌘, and Quit ⌘Q; an Edit menu so copy, paste and undo work in every text field; a Window menu; a Help menu whose Switchtone Help opens Settings > About, which has a "Using Switchtone" section. There is no bundled README and no Help window. ⌘W closes windows, and Esc closes the welcome and About windows and the panel.
6. **Settings window:** one flat sidebar of panes (General, Sounds, Permissions, About) with the pane beside it under its title, the same layout in all these apps, with remembered position and pane. Permissions shows the live status with the same row as the welcome window, and a "Welcome window" row with a "Show Again" button.
7. **Single instance:** a second launch hands over to the first one, which answers as it does for a reopen. Clean quit: SIGTERM is a normal quit, and the control shows off after it.
8. **Polish everywhere:** one capitalization (sentence case for rows, buttons and titles; proper names such as Input Monitoring, System Settings, Login Items and Focus keep theirs); windows open with nothing focused; with the sounds off the sound controls dim; light and dark mode, Reduce Motion, Reduce Transparency and Increase Contrast respected, VoiceOver labels, keyboard navigation in every window, and no layout jumps. Copy is short, human and consistent.

## Design language

docs/DESIGN.md is binding for every surface, icon and word in this app.
