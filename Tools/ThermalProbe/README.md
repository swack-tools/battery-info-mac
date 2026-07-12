# Thermal Probe

`thermal-probe` is a standalone, root-only Swift CLI for inventorying thermal telemetry on macOS 27 Apple silicon systems. It is an experimental discovery tool for deciding which sources are reliable enough to integrate into Battery Monitor later.

It does not modify hardware, install a helper, register a daemon, access the network, or change the production Battery Monitor package. The release executable has no third-party package or runtime dependencies.

## Sources

Each source reports its own status, timing, readings, warnings, capabilities, and error:

- AppleSMC full key enumeration and known numeric datatype decoding
- IOHID EventSystem temperature services
- AppleSmartBattery and AppleSmartBatteryPack temperature properties
- public `ProcessInfo.thermalState`
- dynamically loaded IOReport channels and state residencies
- `powermetrics` thermal, SFI, power-limit, battery, CPU, GPU, and ANE samplers
- `pmset -g therm`
- recursive thermal IORegistry properties and raw AppleCLPC limiter context
- `sysctl` and `system_profiler` thermal capability probes

Unknown values remain source-native and are not assigned Celsius or watt units without evidence. Raw records from independent sources are never deduplicated.

## Build And Test

```bash
cd Tools/ThermalProbe
swift test
swift build -c release --product thermal-probe
```

The executable is written to `.build/release/thermal-probe`.

## Run

```bash
sudo .build/release/thermal-probe
sudo .build/release/thermal-probe --raw
sudo .build/release/thermal-probe --raw --json > thermal-capture.json
sudo .build/release/thermal-probe --jsonl --samples 10 --interval 1000 > thermal-capture.jsonl
```

Options:

- `--json`: emit one complete versioned capture object
- `--jsonl`: emit one self-contained sample record as each sample completes, then one summary record
- `--samples N`: collect a positive number of samples; default is one
- `--interval MS`: sample-start interval in milliseconds; default is 1000
- `--raw`: include undecoded SMC keys, non-temperature context, raw command output, and source metadata
- `--help`: show usage without requiring root

Exit codes:

- `0`: at least one collector produced a reading
- `1`: collection completed but no source produced a reading, or rendering failed
- `64`: invalid command line
- `77`: collection was invoked without root

## Validation Load

`Validation/ThermalLoad.swift` is not linked into `thermal-probe`. It can be compiled separately to exercise CPU and Metal paths while comparing repeated captures:

```bash
xcrun swiftc -O -framework Foundation -framework Metal Validation/ThermalLoad.swift -o .build/thermal-load
sudo .build/release/thermal-probe --json --samples 5 --interval 1000 > /tmp/thermal-idle.json
.build/thermal-load 20 & LOAD_PID=$!
sudo .build/release/thermal-probe --json --samples 5 --interval 1000 > /tmp/thermal-loaded.json
wait $LOAD_PID
```

Sensor values and labels are diagnostic. Private macOS interfaces can change between builds, and this tool must not be used as a hardware-safety controller.
