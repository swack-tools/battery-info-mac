# macOS 27 Thermal Probe Design

**Date:** 2026-07-09

**Status:** Approved for implementation planning

## Goal

Build a standalone, root-only Swift command-line probe that captures as much thermal telemetry as macOS 27 exposes on Apple silicon. The probe is an experimental discovery and validation tool. Its output will identify reliable data sources and sensor mappings before any of the implementation is integrated into Battery Monitor.

The executable must have no third-party package or runtime dependencies. It may use macOS frameworks, private interfaces that are already present in macOS, built-in command-line tools, and a small C interoperability shim compiled into the executable.

## Scope

The probe will:

- run only as root through `sudo`
- enumerate direct AppleSMC and IOHID sensor data
- collect battery, thermal-pressure, power-limit, and throttling context from additional independent sources
- preserve raw sensor identity and values without deduplicating conflicting sources
- classify known sensors conservatively and expose unknown sensors
- support one-shot and repeated sampling
- render a complete human-readable report and structured JSON or JSONL
- isolate source failures so one unavailable private API does not suppress other telemetry

The probe will not:

- modify system settings or hardware state
- install a daemon, helper, launch item, or kernel extension
- make network requests
- depend on macmon, Stats, MacMonitor, Homebrew, Python, or another external executable
- modify or integrate with the Battery Monitor app during this phase
- build a DMG or app bundle during this phase

## Placement And Isolation

The probe will be a separate Swift package under `Tools/ThermalProbe/`. The production `Package.swift`, Battery Monitor targets, privileged helper, Xcode project, DMG workflow, and release workflow will remain unchanged.

The package will produce one executable named `thermal-probe`. Its internal targets will be:

- `ThermalProbe`: argument parsing, root guard, orchestration, and process exit behavior
- `ThermalProbeCore`: collectors, data models, normalization, aggregation, and renderers
- `CThermalProbeShim`: ABI-correct C wrappers for AppleSMC, IOHIDEventSystem, and IOReport
- `ThermalProbeCoreTests`: unit and fixture-based tests that do not require root or hardware access

The C shim is source code in the package and is statically linked into the executable. It is not an external dependency.

## Architecture

The executable follows this pipeline for each sample:

1. Validate that `geteuid()` is zero.
2. Capture host metadata, including timestamp, macOS version and build, hardware model, chip description, and probe schema version.
3. Invoke each collector behind a common interface.
4. Convert collector-specific records into a shared reading model while retaining source-specific metadata.
5. Classify known sensor keys and mark heuristic or unknown classifications explicitly.
6. Build derived summaries separately from raw readings.
7. Render the sample as human-readable text, JSON, or JSONL.

Collectors run sequentially in a deterministic order. This avoids private-API contention and makes failures and timing easier to diagnose. Every source and reading carries its own timestamps, so the report does not imply that a multi-second capture is perfectly simultaneous.

Repeated sampling schedules intervals from the start of one sample to the start of the next. If collection takes longer than the requested interval, the next sample starts immediately and records an overrun warning.

## Collector Interface

Each collector has a stable source identifier and returns a `SourceResult` containing:

- source status: `success`, `partial`, `unavailable`, `failed`, or `timedOut`
- start time and elapsed duration
- zero or more readings
- warnings and a structured error when applicable
- source capability metadata, such as supported samplers or resolved symbols

A collector must not terminate the process. Private API failures, malformed values, absent services, and command failures are converted into the source result. The coordinator continues through all remaining collectors.

## Data Sources

### AppleSMC

The C shim will open the AppleSMC user client, enumerate all exposed keys, read key metadata, and return key name, datatype, byte count, raw bytes, and decoded numeric value when supported.

The decoder will support the integer, fixed-point, floating-point, and temperature datatypes observed in established Apple silicon tools, including `ui8`, `ui16`, `ui32`, signed fixed-point variants, `fpe2`, `flt `, and `sp78`. Unsupported datatypes remain present with their raw bytes.

All keys will be retained in raw mode. Temperature candidates will include keys with known mappings or temperature-like names and plausible decoded units. Known M4 mappings will be classified as CPU, GPU, battery, PMU, NAND, enclosure, or system only when a mapping is backed by observed behavior or a maintained reference. Prefix-only guesses remain heuristic.

### IOHID EventSystem

The C shim will create an IOHID event-system client and enumerate temperature services using the Apple vendor usage page and temperature usage. It will capture product name, registry identity, location identifier, usage page, usage, event timestamp, and temperature value.

Duplicate values and similarly named PMU services will remain separate because they may represent distinct physical sensors or redundant reporting paths.

### AppleSmartBattery

An IOKit collector will read AppleSmartBattery properties directly. It will capture current temperature, virtual temperature, lifetime minimum, lifetime average, lifetime maximum, and thermally limited charging time when exposed. Nested battery dictionaries will be flattened without losing their original property paths.

### Process Thermal State

The public Foundation `ProcessInfo.thermalState` value will be recorded as nominal, fair, serious, or critical. It is system pressure context, not a Celsius reading.

### Powermetrics

The collector will inspect the installed `powermetrics` capabilities and intersect requested samplers with those supported by the current OS. It will request thermal pressure, SFI forced-idle data, power limits, and available CPU, GPU, ANE, battery, and related power samplers.

Structured plist output will be preferred when the installed command supports it. A version-tolerant text parser will cover fields not available in plist output. The absence of the historical `smc` sampler on macOS 27 will be reported as a capability fact, not treated as a collection failure.

### PMSet

The probe will run `pmset -g therm` and retain the complete command result alongside normalized thermal warning, performance warning, and CPU power status fields. A response stating that no warning has been recorded maps to nominal pressure without inventing a temperature.

### IOReport

The optional C shim will resolve IOReport symbols dynamically and enumerate available channels. It will sample relevant groups such as Thermal, Energy Model, CPU Stats, GPU Stats, and other power-management groups exposed by the host.

Channel group, subgroup, channel name, state, unit, and raw sampled values will be retained. Values with unclear or undocumented units will remain raw context and will not be labeled as Celsius or watts until their semantics are established.

### IORegistry And AppleCLPC

A generic IOKit registry walker will capture properties whose names or paths contain temperature or thermal concepts. It will preserve service class, registry path, property path, datatype, and value.

AppleCLPC power-limit and thermal-target properties will be captured as raw limiter context. Undocumented target fields will not be presented as temperatures.

### Capability Probes

Built-in `sysctl` and `system_profiler` surfaces may be checked for temperature or thermal fields. A successful probe with no relevant fields is recorded as an available source with zero readings. These probes exist to document macOS 27 behavior; they are not expected to provide primary sensor data.

The probe will not scrape unified logs, reverse-engineer thermald state files during normal execution, or claim that an undocumented scalar is a temperature without evidence.

## Shared Data Model

The top-level `CaptureEnvelope` contains:

- schema version
- invocation and host metadata
- requested sample count and interval
- one or more `ThermalSample` values
- process-level warnings

Streaming output uses a tagged `StreamRecord`. A `sample` record repeats the schema, host, and invocation metadata needed to interpret its `ThermalSample`; after the requested samples complete, one `summary` record contains capture-wide aggregates and process warnings. This keeps every line independently decodable without withholding live samples until the end.

Each `ThermalSample` contains source results, normalized readings, and derived summaries. Each `Reading` includes:

- source identifier
- source-native identifier or key
- optional display label
- category such as CPU, GPU, battery, PMU, NAND, enclosure, system, or unknown
- kind such as temperature, thermal pressure, power limit, forced idle, power, duration, or raw context
- numeric or textual value and unit
- reading timestamp
- classification level: `known`, `heuristic`, or `unclassified`
- source-specific metadata
- plausibility warnings
- raw datatype and bytes when raw output is requested

Metadata uses a Codable JSON-value representation so numbers, strings, booleans, arrays, and dictionaries retain their types.

Raw records are never removed because another source reports the same value. Derived summaries are separate records and link back to their contributing source identifiers.

## Classification And Summaries

The classifier uses an explicit mapping table for known Apple silicon sensor keys. M4 and M4-family CPU and GPU mappings are included where maintained open-source references and live behavior agree. Unknown `T...` keys remain visible and may receive a heuristic category without receiving a confident component label.

Plausibility checks flag non-finite values and temperatures outside a broad diagnostic range. Flagged values remain in raw output. The probe does not silently clamp or drop them.

For each confidently classified component, the summary may calculate current minimum, average, and maximum. Repeated sampling additionally calculates per-sensor minimum, average, maximum, and delta over the capture. A summary cannot replace or hide its source readings.

## Command-Line Interface

Supported invocation forms are:

```text
sudo thermal-probe
sudo thermal-probe --json
sudo thermal-probe --jsonl --samples 10 --interval 1000
sudo thermal-probe --raw
```

Behavior:

- default output is a readable source-status report followed by every normalized temperature and thermal-context reading
- `--json` emits one complete `CaptureEnvelope`
- `--jsonl` emits a tagged, self-contained `sample` record per line as it completes, followed by one tagged `summary` record after the final sample
- `--samples N` defaults to one and must be a positive integer
- `--interval MS` must be a positive integer, controls the sample-start interval, and defaults to 1000 milliseconds when more than one sample is requested; it has no effect for a single sample
- `--raw` adds undecoded SMC payloads, non-temperature candidates, and full source metadata to human or structured output
- diagnostics are represented in structured output and are sent to standard error in human mode
- output files are handled through ordinary shell redirection; the probe does not need a separate persistence layer

Repeated human output renders each sample as it completes and prints capture-wide aggregates after the final sample. JSON output buffers the requested samples into one `CaptureEnvelope`; JSONL is the streaming form.

`--json` and `--jsonl` are mutually exclusive. Unknown options and invalid numeric values are usage errors.

## Exit Codes

- `0`: at least one collector produced a usable result, including runs with partial source failures
- `1`: the probe ran but no collector produced usable data
- `64`: command-line usage error
- `77`: the process is not running as root

A partial failure is visible in source results and diagnostics but does not change a useful capture into a process failure.

## Error Handling And Cleanup

Private symbols are resolved defensively. An unavailable symbol or rejected user-client connection marks only that collector unavailable or failed. Core Foundation and IOKit objects are released by the C shim according to their ownership rules.

Built-in child commands use explicit executable paths and a 16 MiB combined-output limit per invocation. Powermetrics gets a 15-second timeout around its one-second sample; other capability commands get a 5-second timeout. Timeout or signal handling terminates owned child processes and releases open clients. The probe never writes to system configuration or persistent state.

Malformed command output is retained for diagnostics when raw mode is enabled. Parsers return partial results when individual fields are valid instead of rejecting the whole source.

## Testing Strategy

Implementation will proceed test-first. Unit tests will cover:

- AppleSMC datatype decoding, byte order, invalid sizes, and non-finite values
- known and heuristic CPU, GPU, battery, PMU, and unknown sensor classification
- powermetrics plist and text fixtures, including missing sampler behavior
- pmset nominal, warning, and malformed-output fixtures
- IORegistry nested-value flattening and metadata typing
- source-result aggregation and partial-failure isolation
- repeated-sample min, average, max, delta, and interval-overrun behavior
- JSON and tagged JSONL sample/summary serialization and round trips
- argument validation and exit-code decisions

Hardware-independent tests will use injected collector and command-runner interfaces. Unit tests will not require root.

Root integration validation on the macOS 27 M4 test machine will include:

1. Build and run the release executable with every collector enabled.
2. Confirm every collector reports a status even when it has zero readings.
3. Confirm AppleSMC and IOHID expose broad inventories and known M4 CPU and GPU candidates are present.
4. Confirm battery readings from AppleSmartBattery overlap plausibly with battery-related SMC or IOHID readings.
5. Capture repeated idle samples and verify timestamps, aggregation, and JSONL validity.
6. Apply a short controlled CPU and GPU workload outside the probe and verify responsive candidates change plausibly without treating an exact temperature as an assertion.
7. Deliberately disable or fail one injectable collector and verify all other sources still render.
8. Round-trip a full raw JSON capture without losing identifiers, datatypes, metadata, or diagnostics.

The approximately 186 readable SMC temperature-like values and 43 IOHID temperature services observed during design research are machine-specific diagnostic baselines. They are not hard pass criteria for other hardware or future macOS builds.

## Acceptance Criteria

The experimental CLI is complete when:

- the independent package builds in debug and release configurations without third-party dependencies
- non-root execution exits with code 77 before collection begins
- a root run on the macOS 27 test machine completes without crashing and reports every configured source
- direct AppleSMC and IOHID collectors expose raw inventories and find known M4 CPU and GPU candidates
- AppleSmartBattery, ProcessInfo, powermetrics, pmset, IOReport when available, and IORegistry results are represented independently
- one collector can fail or time out without suppressing other results
- human, JSON, JSONL, repeated, and raw modes behave as specified
- all unit tests pass and a full root capture survives JSON round-trip validation
- no production Battery Monitor target, package, helper, project, or release artifact is changed

## Risks And Mitigations

- **Private API drift:** Keep private calls behind the C shim, resolve optional symbols dynamically, and report source availability explicitly.
- **Incorrect sensor labels:** Separate known mappings from heuristics, retain native identifiers, and validate candidates under changing load.
- **Nonsensical decoded values:** Preserve raw bytes, attach plausibility warnings, and never silently discard a record.
- **Command output drift:** Prefer structured formats, keep versioned fixtures, and return partial parse results with diagnostics.
- **Unclear IOReport or AppleCLPC units:** Treat undocumented values as raw context until independently validated.
- **Collection latency:** Record per-source timing and interval overruns so repeated captures remain interpretable.

## Reference Boundary

Open-source projects such as Stats, MacMonitor, macmon, and freedomtan/sensors may be used as implementation references for public structure definitions, known sensor mappings, and private-framework calling patterns. They are not runtime dependencies. Any source code adapted rather than independently implemented must retain the applicable license notice and be documented in the package.

## Future Integration

Battery Monitor integration is a separate follow-up project. The probe's versioned data model and source diagnostics are designed to make reliable collectors extractable later, but this phase will not modify the app or assume that every experimental source belongs in production.
