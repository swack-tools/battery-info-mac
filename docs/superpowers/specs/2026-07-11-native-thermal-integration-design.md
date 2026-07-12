# Native Thermal Integration Design

## Goal

Restore useful CPU, GPU, battery, memory, storage, PMU, and enclosure temperatures on macOS 27 without external dependencies. The production app will absorb the proven standalone probe behavior, use only Swift system bindings, and expose both a compact thermal summary and a complete advanced sensor view.

The privileged helper is always expected to run as root. The menu-bar process remains unprivileged and reads an atomic telemetry snapshot written by the helper.

## Scope

- Port the successful AppleSMC, IOHID, IOReport, AppleSmartBattery, IORegistry, `ProcessInfo`, `powermetrics`, and `pmset` collection paths to native Swift.
- Remove `Tools/ThermalProbe`, including the C shim and standalone CLI, after its tested behavior has been integrated.
- Keep the current helper registration and cache mechanism.
- Replace the current battery-dominated General Thermals list with representative current temperatures.
- Add a Thermals Advanced section directly below General Thermals.
- Build a release DMG, install the resulting app in `/Applications`, and verify a live privileged snapshot.

## Architecture

The main Swift package gains a `BatteryMonitorThermal` library target. It depends on `BatteryMonitorShared`, links IOKit, and contains the native collectors and system bindings. `BatteryMonitorPrivilegedHelper` depends on this target and coordinates collection. `BatteryMonitor` does not link the private system bindings.

`BatteryMonitorShared` owns the Codable snapshot contract, thermal categories, source statuses, parsers, classification, and summary aggregation. This keeps the GUI and helper in agreement without exposing privileged collection code to the GUI process.

Native Swift system access uses:

- IOKit functions and exact Swift ABI structures for AppleSMC calls.
- `dlopen` and typed `@convention(c)` function pointers for private IOHID and IOReport symbols.
- IOKit registry APIs for battery and registry telemetry.
- Foundation `Process` for bounded `powermetrics` and `pmset` execution.

Missing private symbols or changed operating-system behavior produce an unavailable source result rather than a helper crash.

## Snapshot Contract

The existing `ThermalSnapshot` fields remain valid:

- `thermalReadings` contains representative readings for General Thermals.
- `componentPowers`, `throttling`, `thermalPressure`, and `messages` retain their current behavior.

The snapshot adds:

- Detailed sensor readings with source, stable identifier, display label, category, kind, numeric or text value, unit, classification, and warnings.
- One result per attempted source with status, reading count, duration, warnings, and an optional error.

Decoding supplies empty defaults for new arrays so an installed app can read an older helper cache during an upgrade. The helper continues to write snapshots atomically every 10 seconds.

Raw SMC bytes and thousands of unrelated IOReport energy channels are not persisted. Source diagnostics record how many records were scanned and emitted.

## Collection And Aggregation

Each collector runs independently and returns `success`, `partial`, `unavailable`, or `failed`. A failed collector cannot discard successful readings from another collector.

Only finite and plausible temperatures are eligible for the summary. Detailed readings retain questionable values only when they carry a warning, allowing the advanced view to expose the source without presenting it as a trusted summary value.

Representative summary values are selected by category and source confidence:

- CPU, GPU, and memory prefer AppleSMC.
- Battery prefers the current AppleSmartBattery/IOKit reading and excludes lifetime minimum, average, and maximum values.
- Storage/NAND, PMU, enclosure, and other system temperatures prefer labeled IOHID readings.
- `powermetrics` and other validated temperature sources are fallbacks.

Within the selected source for a category, General Thermals displays the hottest current plausible sensor. Stable category names prevent the UI from resizing or duplicating rows when individual sensor keys change.

Component power and throttling continue to come from `powermetrics`, `pmset`, and thermal-pressure data. Duplicate power rows are collapsed by component.

## User Interface

General Thermals remains an existing-style disclosure section. It shows representative current CPU, GPU, battery, memory, storage/NAND, PMU, enclosure, and system values when available, followed by throttling and component power. If the helper has no current data, it shows the precise helper status.

Thermals Advanced appears immediately below General Thermals and is collapsed by default. Inside it, readings are grouped by source. Each source header shows its status and emitted-reading count; expanding a source shows every thermal temperature or pressure reading with label, identifier, value, and classification. Source warnings and errors appear inline in a compact secondary style.

The advanced view does not label generic IOReport power, residency, or timing channels as temperatures. Those channels remain source diagnostics unless the system supplies a temperature unit and thermal name.

The implementation follows the app's existing disclosure, typography, color-band, and `InfoRow` patterns. It adds no decorative containers or separate window.

## Error Handling

- AppleSMC layout and call failures are isolated to the SMC source.
- IOHID and IOReport symbol lookup failures become unavailable source results.
- Commands have timeouts and preserve partial parsed output when useful.
- Invalid, nonfinite, and implausible values cannot enter General Thermals.
- Snapshot encoding or write failures are logged by the helper without corrupting the previous cache.
- The app distinguishes helper registration, stale telemetry, and individual source failures.

## Testing

Automated coverage will include:

- AppleSMC ABI `MemoryLayout`, FourCC conversion, decoding, and sensor classification.
- IOHID and IOReport record mapping through fixture providers without invoking private APIs in tests.
- Battery and registry temperature conversion.
- Summary source priority, maximum selection, lifetime-value exclusion, deduplication, and plausibility filtering.
- Backward-compatible decoding of the old snapshot shape.
- Source failure isolation and status rendering.
- General and advanced thermal section structure.
- Project-structure checks proving no C source or `CThermalProbeShim` reference remains.

Verification requires the full Swift test suite, release builds of the app and helper, a DMG build, app installation, and a root helper one-shot capture showing non-battery thermal sources on the current macOS 27 host. Private API availability is reported from the live capture rather than assumed.

## Completion Criteria

- The repository contains no thermal C shim or standalone ThermalProbe package.
- Production thermal collection is Swift-only and has no external dependency.
- General Thermals includes CPU/GPU-class readings when the host exposes them.
- Thermals Advanced exposes all valid collected thermal readings grouped by source.
- A failure in one source remains visible and does not hide other telemetry.
- Tests and release builds pass.
- The generated DMG is installed to `/Applications/BatteryMonitor.app` and the installed helper produces a fresh telemetry snapshot.
