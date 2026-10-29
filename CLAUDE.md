# Sector

macOS disk usage analyzer and cleaner. Swift 6 + SwiftUI, macOS 26+,
distributed outside the App Store (no sandbox). Key product qualities: speed,
beauty and smooth motion.

The design lives in `design/mockups/*.dc.html` (one HTML mock per screen,
Russian UI). `DesignSystem.dc.html` holds the tokens; `canvas.json` lists the
boards and their titles. Read the matching mock before building a screen:
markup gives layout and copy, the `<script data-dc-script>` block gives the
sample data and interactions, `<helmet><style>` the animations.

## Build and test

```sh
scripts/build-app.sh          # release build → build/Sector.app (ad-hoc signed)
scripts/build-app.sh debug
scripts/test.sh               # swift-testing suite
scripts/check-strings.sh      # untranslated UI strings
swift scripts/make-icon.swift # re-render Resources/AppIcon.icns
swift build -c release --product sector-bench && .build/release/sector-bench ~/path
```

Always build through the scripts or `source scripts/env.sh` first: without
Xcode, Command Line Tools miss the SwiftUI macro plugin of the macOS 27 SDK,
and `env.sh` switches to the macOS 26 SDK.

## Layout

- `Sources/SectorCore` — UI-free engine, unit-tested.
  - `Scanner/` — `DiskScanner` (parallel `getattrlistbulk`), `FileTree`
    (structure-of-arrays tree; children contiguous, child index > parent).
  - `Categories/` — `DiskCategory`, `CategoryBreakdown` (overview donut).
  - `Removal/` — `FileRemover` (Trash or permanent, restore).
  - `History/` — `HistoryStore` (cleanup records, free-space samples).
  - `Volumes/`, `Format/` (`ByteFormat`: "64,8 ГБ"), `Metadata/`
    (Spotlight last-used date, APFS private size, Full Disk Access check).
- `Sources/Sector` — the app.
  - `App/` — `SectorApp` (scenes), `AppModel` (scan, tree, deletion, history,
    toasts), `AppSettings`, `Route`.
  - `Design/` — `Theme.swift` (colors, `Metrics`, `Motion`, fonts) and
    `Components.swift` (`Card`, `PageHeader`, `IconBadge`, `SizeText`,
    `CountingBytes`, `ProgressRing`, `SegmentedBar`, `SelectionCheck`,
    `SafetyBadge`, `EmptyStateView`, `AmbientBackground`, `.appearAnimation`).
  - `Shell/` — `RootView` (onboarding vs main), `MainView` (split view,
    sidebar, toast, confirmation sheet).
  - `Features/<Screen>/` — one folder per screen, with its views and model.

## Conventions

- Swift style: 2-space indent, 100 columns (`.swift-format`).
- UI strings are Russian literals (`Text("Обзор")`, `String(localized:)`);
  Russian is the source language and the localization key. English goes in
  `Resources/en.lproj/Localizable.strings`; `scripts/check-strings.sh` lists
  keys missing a translation. Counted nouns use `Plural.format(n, one, few,
  many)`, whose forms are looked up as keys too. Text passed through a
  `String` parameter is not localized — take `LocalizedStringKey` or call
  `String(localized:)` at the call site.
- Use the tokens: colors `Color.sector*`, category colors
  `DiskCategory.color`, radii `Metrics`, animations `Motion.smooth / bouncy /
  quick / counter` wrapped in `Motion.resolve(_:)` so Reduce Motion and the
  in-app toggle are honored. SF Symbols for icons.
- Native chrome (NavigationSplitView, toolbar, sheets, `.glass` /
  `.glassProminent` button styles); content follows the mocks.
- Never block the main actor with file system work: scan/hash/size off-main
  (`Task.detached`), publish results on the main actor.
- Deleting always goes through `AppModel.requestDeletion` (confirmation sheet,
  Trash by default, History record) unless a flow records its own cleanup via
  `AppModel.recordCleanup`.
- Numbers use tabular digits (`.monospacedDigit()`).
