# Estimated Battery Throughput Design

## Goal

Replace the misleading Lifetime Energy estimate with an auditable estimate of cumulative battery discharge throughput based on cycle count and Apple-rated battery energy capacity.

## Problem

Battery Monitor currently reads the undocumented IORegistry field `PowerTelemetryData.AccumulatedSystemEnergyConsumed` and divides it by 1,000,000,000 using an empirically guessed conversion. The same field differs dramatically between hardware generations: it produces approximately 0.1 kWh on a 311-cycle M4 MacBook Air and 14.7 kWh on a nearly new M5 Mac. Neither value is credible battery throughput.

The fallback multiplies total operating time by instantaneous battery power. A present-time power sample cannot reconstruct historical energy use, so that result is also unsuitable.

## Calculation

For a model with a known Apple-rated battery capacity:

```text
estimated throughput kWh = cycle count * rated battery Wh / 1000
```

For the 13-inch M4 MacBook Air (`Mac16,12`), Apple specifies 53.8 Wh. At 311 cycles:

```text
311 * 53.8 Wh / 1000 = 16.7318 kWh
```

The UI rounds this to one decimal place and displays approximately 16.7 kWh.

This value represents cycle-equivalent battery discharge throughput. It is not total system electricity consumption, energy drawn directly from the adapter, or wall energy including charging losses.

## Architecture

Add a small battery specification catalog keyed by the stable `machine_model` identifier already returned by `SystemCommands.getSystemInfo()`. Each entry contains the Apple-rated battery capacity in watt-hours and a human-readable source note in code comments.

The initial catalog contains:

| Model identifier | Product | Rated capacity |
| --- | --- | ---: |
| `Mac16,12` | MacBook Air 13-inch, M4 | 53.8 Wh |

Unknown models return no capacity and therefore show no throughput row. The app must not infer nominal voltage from instantaneous pack voltage, guess from mAh, or reuse the undocumented energy accumulator.

Place the pure lookup and calculation in the battery data model layer so they are independently testable. `BatteryDisplayInfo` combines cycle count with the current machine identifier and formats the result for the UI.

## Data Removal

Remove the following obsolete path:

- `BatteryData.accumulatedSystemEnergy`
- parsing of `AccumulatedSystemEnergyConsumed`
- `BatteryData.lifetimeEnergyKWh`
- its operating-time and instantaneous-power fallback
- the `BatteryDisplayInfo.lifetimeEnergy` display field

Do not remove `totalOperatingTime`; it supports separate lifetime diagnostics.

## User Interface

In Advanced Diagnostics, replace:

```text
Lifetime Energy    ~0.1 kWh (est)
```

with:

```text
Estimated Battery Throughput    ~16.7 kWh
```

The row is absent when the cycle count is zero, the rated capacity is unavailable, or the calculated result is nonpositive or nonfinite.

## Testing

Unit tests cover:

- `Mac16,12` resolves to 53.8 Wh.
- An unknown model resolves to no specification.
- 311 cycles at 53.8 Wh produces 16.7318 kWh.
- Zero and negative cycle counts produce no estimate.
- Display formatting produces `~16.7 kWh` for the known model.
- The row remains absent for an unknown model.
- Source and project-structure tests prove the undocumented accumulator parsing and old Lifetime Energy label are removed.

The complete Swift test suite and repository lint checks must pass.

## Scope

This change initially supports only `Mac16,12`. Additional Mac models, including the user's M5, require their exact `machine_model` identifier and Apple-rated battery capacity before being added. The change does not estimate wall energy, charging losses, adapter-only consumption, or battery health degradation over time.
