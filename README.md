# Cpuer

SwiftUI menu bar app for monitoring macOS CPU stats.

> [!NOTE]
> I loved Simon Willison's [Gpuer](https://github.com/simonw/gpuer) (GPU/memory) and [Bandwidther](https://github.com/simonw/bandwidther) (network) menu bar tools but couldn't find one for CPU — so I asked [GitHub Copilot CLI](https://github.com/github/copilot-cli) to create one using his code as the reference. The architecture, UI patterns, and overall design are derived from Simon's work. See [CREDITS.md](CREDITS.md) for full attribution.
>
> Simon's original repositories do not include an explicit license. If you are the author and have concerns, please open an issue.

## Features

- **"Active" headline** showing overall CPU utilization as a percentage, with a plain-English estimate of busy cores
- **CPU breakdown bar** showing user, system, and idle as competing claims on total CPU time
- **Per-core utilization grid** with P-core and E-core groups labeled separately (Apple Silicon)
- Live load averages (1, 5, 15 min)
- System uptime display
- Two-minute sparklines for total CPU, user, and system utilization
- Per-process CPU usage with sorting by CPU, memory, name, or PID
- Two-column menu bar popover: stats on the left, process list on the right

## How measurement works

Cpuer uses macOS system interfaces rather than shelling out to `top` or `htop`.

### CPU utilization

- **Per-core ticks** come from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, a Mach kernel call that returns cumulative user/system/idle/nice tick counts per logical core.
- **Percentages** are computed from the delta between consecutive samples (every 2 seconds). This is the same technique `top` uses internally — no subprocess overhead.
- **Wrapping subtraction** (`&-`) handles UInt32 overflow on long-running systems.
- **P-core / E-core detection** uses `sysctlbyname("hw.perflevel0.logicalcpu")` and `hw.perflevel1.logicalcpu`, which are Apple Silicon–specific. On Intel Macs, all cores are shown as a single group.

### Load averages and uptime

- Load averages come from `getloadavg()`.
- Uptime is derived from `sysctl kern.boottime`.

### CPU model and core counts

- CPU model string from `machdep.cpu.brand_string` via sysctl.
- Physical and logical core counts from `hw.physicalcpu` / `hw.logicalcpu`.

### Per-process CPU

- Process list comes from `ps -eo pid,pcpu,rss,comm -r`.
- Processes are aggregated by executable name with a count shown (e.g. `node (10)`).
- Memory shown alongside CPU for context (RSS from `ps`).

### Important limitations

- P/E core detection depends on Apple Silicon `hw.perflevel*` sysctl keys. Intel Macs will show all cores in a single group.
- `machdep.cpu.brand_string` may not be available on all Apple Silicon Macs — falls back to "Apple Silicon".
- The `ps` process aggregation by binary name can merge unrelated processes with the same executable name.
- CPU frequency is not shown — Apple Silicon does not expose this through public sysctl keys.

## Building

```bash
git clone <repo-url>
cd cpuer
swiftc -parse-as-library -framework SwiftUI -framework AppKit -framework IOKit -o Cpuer CpuerApp.swift
./Cpuer
```

Requires macOS and Xcode command line tools (`xcode-select --install`).

## Prerequisites

- macOS with the Swift toolchain from Xcode command line tools (`xcode-select --install`). No explicit deployment target is declared in this repo — there is no `Package.swift`, `.xcodeproj`, or `Info.plist`; the build command in the section above invokes `swiftc` directly against `CpuerApp.swift`, so the minimum supported macOS version is whatever your installed Swift toolchain targets by default.
- Apple Silicon recommended for the P-core / E-core split. The split uses `hw.perflevel0.logicalcpu` / `hw.perflevel1.logicalcpu` (`CpuerApp.swift` lines 97–99); when those keys are unavailable the helper returns `(0, 0)` and the UI reports 0 P-cores and 0 E-cores. The existing [Important limitations](#important-limitations) section already describes this behavior for Intel Macs.

## Troubleshooting

- **P-core / E-core counts both show 0**: the `hw.perflevel*` sysctl keys returned no value (typical on Intel Macs). Per-core utilization is still collected from `host_processor_info` and displayed, only the P/E grouping is missing.
- **CPU model shows "Apple Silicon" instead of a specific chip name**: `machdep.cpu.brand_string` was unavailable — the existing fallback at the top of `CpuerApp.swift` kicks in (see the README's *Important limitations*).
- **Process list merges unrelated processes**: expected behavior — `ps -eo pid,pcpu,rss,comm -r` is aggregated by executable name. Already noted in *Important limitations*.

## Known Limitations

The repository already documents measurement limitations under [Important limitations](#important-limitations) above. Additional notes:

- Sampling intervals are hardcoded: 2.0 s for CPU ticks / per-process, 5.0 s for the slower refresh (`CpuerApp.swift` lines 298 and 301). There is no Preferences UI to change them — editing these values requires a source edit and rebuild.
- Build produces a standalone unsigned binary. No code signing, notarization, or `.app` bundle is created by the `swiftc` command in [Building](#building).
