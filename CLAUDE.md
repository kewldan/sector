# Sector

Native macOS disk usage analyzer and cleaner. Swift 6 + SwiftUI, macOS 26+
(designed for macOS 27), distributed outside the App Store, so the app is not
sandboxed (the widget extension is). Product priorities, in order: speed,
beauty, smooth motion. Russian and English UI.

## Design source

`design/mockups/*.dc.html` is the original design, one HTML mock per screen
(Russian copy); `canvas.json` lists the boards and their titles and
`DesignSystem.dc.html` holds the tokens. Before building or changing a screen,
read its mock: markup gives layout and copy, the `<script data-dc-script>`
block gives sample data and interactions, `<helmet><style>` the animations.
Never ship the mocks' sample numbers — every figure comes from real data.

## Build, run, test

```sh
scripts/build-app.sh          # xcodegen + xcodebuild → build/Sector.app (release)
scripts/build-app.sh debug
scripts/install.sh            # release build → /Applications/Sector.app, relaunched
scripts/test.sh               # swift-testing suite of SectorCore
scripts/check-strings.sh      # UI strings missing English (run after build-app.sh)
swift scripts/make-icon.swift # re-render Resources/AppIcon.icns from code
swift build -c release --product sector-bench && .build/release/sector-bench ~/path
```

- The Xcode project is generated from `project.yml` and not committed. It has
  two targets on top of the `SectorCore` package: the app and the WidgetKit
  extension. Info.plists and entitlements are generated from `project.yml` too
  — edit them there, never the generated files.
- Signing: `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` (not committed).
  Without it builds are signed ad hoc: the app runs, but the widgets get no
  App Group, and macOS forgets Full Disk Access on every rebuild because the
  code signature changes.
- `scripts/env.sh` only matters without Xcode: Command Line Tools lack the
  SwiftUI macro plugin of the macOS 27 SDK (`@State` is a macro there), so it
  falls back to the macOS 26 SDK for `swift build`/`swift test`.
- Launch with `-onboarded NO` to see onboarding without touching saved
  settings, or `-AppleLanguages '(ru)'` for the Russian UI.

## Architecture

- `Sources/SectorCore` — UI-free engine, unit-tested in `Tests/SectorCoreTests`.
  - `Scanner/` — `DiskScanner` and `FileTree` (see invariants below),
    `FileTreeCache` (binary snapshot for instant launch).
  - `Categories/` — `DiskCategory`, `CategoryBreakdown` (overview donut).
  - `Cleanup/` — Smart Clean rules (`CleanupAnalyzer`), the runner, Docker and
    simulator inspectors (shell out to `docker` / `xcrun simctl`).
  - `Duplicates/`, `Apps/` (`AppInventory`), `Layout/` (sunburst, treemap,
    largest folders), `Removal/` (`FileRemover`), `History/` (`HistoryStore`:
    cleanup records and daily free-space samples), `Volumes/`, `Metadata/`
    (Spotlight last-used date, APFS private size, Full Disk Access probe),
    `Format/` (`ByteFormat`, `Plural`), `Widget/` (`WidgetSnapshot`).
- `Sources/Sector` — the app.
  - `App/` — `SectorApp` (window, Settings, menu bar scenes), `AppModel` (scan,
    tree, deletion, history, toasts, `sector://` URLs), `AppSettings`, `Route`.
  - `Design/` — tokens in `Theme.swift`, shared views in `Components.swift`.
  - `Shell/` — onboarding vs main window, sidebar, toast, confirmation sheet.
  - `Features/<Screen>/` — one folder per screen with its views and model;
    `Features/System/` holds notifications, the weekly background scan and
    `WidgetBridge`.
- `Widgets/` — WidgetKit extension; reads `WidgetSnapshot` from the App Group
  container and re-reads free space live.
- `Sources/sector-bench` — command-line benchmark for the scanner.

## Invariants and gotchas

- `FileTree` is a structure of arrays. A directory's children are contiguous
  and every child index is greater than its parent's — sizes roll up in one
  reverse pass and many algorithms rely on it. Only `FileTree.remove` mutates
  it, on the main actor, and only ever shrinks sizes.
- After a scan or removal, `AppModel.treeVersion` changes; screens recompute
  derived data off the main actor keyed on it, never on every render.
- Opening a privacy-protected folder (Desktop, Documents, other apps' data…)
  blocks in `openat` until the user answers a system prompt. Without Full
  Disk Access the scanner skips `AppModel.privacyProtectedPaths`, and the
  `WorkQueue` gives up on opens stuck longer than 4 s so a scan always
  finishes; skipped folders are flagged `.denied` and surface in the
  "No access to N folders" banner.
- Custom `Layout`s must not measure children with a `nil` height and trust
  the answer: Swift Charts report an unbounded ideal height and blow up the
  whole split view. Bound the proposal (see `RatioHStack` in History).
- Deleting goes through `AppModel.requestDeletion` (confirmation sheet, Trash
  by default, History record). Flows that remove on their own (Smart Clean,
  Docker) report through `AppModel.applyRemoval` + `recordCleanup`. Emptying
  the Trash is always permanent. The menu bar "Clean" runs Smart Clean's safe
  selection without a sheet, as in the design.
- Smart Clean removal must never follow symlinks out of a target, cross mount
  points, or touch anything shallower than two levels inside the home folder;
  `Docker.raw` is off limits. Never run cleanups against real data in tests —
  use temp fixtures.

## Conventions

- Swift style: 2-space indent, 100 columns (`.swift-format`).
- UI strings are Russian literals (`Text("Обзор")`, `String(localized:)`):
  Russian is the source language and the localization key. English lives in
  the String Catalog `Resources/Localizable.xcstrings`; `xcodebuild` does not
  add new keys to it, so run `scripts/check-strings.sh` and add translations
  by hand. Counted nouns use `Plural.format(n, one, few, many)`; each form is
  a key too. Text passed through a `String` parameter is not localized — take
  `LocalizedStringKey` or call `String(localized:)` at the call site. When one
  Russian word needs different English in different places, use a dotted key
  with both translations in the catalog (`toast.undo`, `trash.empty`).
- Design tokens only: `Color.sector*`, `DiskCategory.color`, `Metrics`, fonts
  from `Theme.swift`, animations `Motion.smooth / bouncy / quick / counter`
  wrapped in `Motion.resolve(_:)` so Reduce Motion and the in-app toggle work.
  SF Symbols for icons, tabular digits (`.monospacedDigit()`) for numbers.
- Native chrome (NavigationSplitView, toolbar title and subtitle, sheets,
  `.glass` / `.glassProminent`); content follows the mocks. Screens put their
  title in the toolbar with `.navigationTitle` / `.navigationSubtitle`.
- No file-system work or process spawning on the main actor: `Task.detached`,
  publish results back on the main actor.
- New engine logic goes into `SectorCore` with tests.

## Verifying UI changes

Build and install, then look at the real app — most layout bugs here only
show up with real data. `screencapture -l <window id> -x out.png` captures a
window with its shadow even when it is behind other windows (`-o` drops the
shadow). README screenshots live in `docs/screenshots/`, the GIF in `docs/`;
retake them in English when a screen changes noticeably.

## Git

Work on `main`; Conventional Commits (`feat(scope): …`, `fix: …`, `docs: …`).
