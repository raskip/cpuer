# Credits & Attribution

Cpuer would not exist without the following projects by **Simon Willison** ([@simonw](https://github.com/simonw)):

## Original projects

- **[Gpuer](https://github.com/simonw/gpuer)** — SwiftUI menu bar app for monitoring macOS GPU and memory stats
- **[Bandwidther](https://github.com/simonw/bandwidther)** — SwiftUI menu bar app for monitoring macOS network bandwidth

## What was derived from Simon's work

### Architecture
- Single-file SwiftUI app pattern (`@main struct` → `AppDelegate` → `NSStatusBar` → `NSPopover`)
- `ObservableObject` monitor class with dual-timer refresh (fast for stats, slow for process list)
- Background data collection on `DispatchQueue.global(qos: .utility)` with main-thread UI updates

### UI components (adapted/reimplemented)
- `SparklineView` — line chart with gradient fill using `GeometryReader` + `Path`
- `UsageBarView` — stacked horizontal bar chart from fraction/color segments
- `RateCardView` — stat card with icon, title, large value, and subtitle
- `SectionHeader` — icon + title row
- `SortButton` — process sort toggle with chevron indicator
- `ProcessRowView` — process name + bar + metric display
- Two-column `ContentView` layout (stats left, process list right)

### Design patterns
- Color-coded headline stat (green/orange/red based on thresholds)
- Monospaced fonts for numeric values
- Process aggregation by executable name with count
- Menu bar popover with `.transient` behavior
- `NSApp.setActivationPolicy(.accessory)` for menu-bar-only app

### Build approach
- Single `swiftc` command with system frameworks, no Xcode project

## What is new in Cpuer

- CPU utilization via `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` Mach kernel API (no subprocess)
- Delta-based per-core tick computation with wrapping subtraction
- P-core / E-core detection via `hw.perflevel*` sysctl keys (Apple Silicon)
- Per-core utilization grid (`CoreGridView`, `CoreBarView`)
- Load average display via `getloadavg()`
- System uptime via `kern.boottime`
- User/system split sparkline history
- CPU-focused process row (CPU% as primary metric, memory as secondary)

## How this was built

This app was generated using AI-assisted coding (GitHub Copilot CLI) with Simon Willison's Gpuer and Bandwidther source code as reference implementations. The AI was asked to create a CPU monitoring companion app following the same patterns and visual style.

## License note

As of the time of creation, Simon's original repositories (simonw/gpuer and simonw/bandwidther) do not include an explicit open-source license. This means all rights are reserved by default under copyright law. This project is published in good faith with full attribution. If the original author has concerns, please open an issue.
