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
