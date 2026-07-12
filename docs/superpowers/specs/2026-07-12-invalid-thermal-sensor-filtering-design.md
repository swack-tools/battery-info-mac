# Invalid Thermal Sensor Filtering Design

## Goal

Remove confirmed-unreliable thermal sensors before they enter Battery Monitor's detailed telemetry so they appear in neither General Thermals nor Thermals Advanced.

## Evidence

Live privileged-helper snapshots exposed two distinct failure classes:

- SMC key `TVDi` produced impossible values such as 167,772,160 C and 218,103,808 C.
- IOHID products `PMU tdev1`, `PMU2 tdev1`, and `PMU2 tdev3` repeatedly produced approximately -21.8 C while sibling PMU sensors reported plausible internal temperatures between approximately 42 C and 69 C.

These are stable sensor identities, not isolated display-formatting errors. Keeping them with warning text makes Thermals Advanced misleading and leaves invalid data available to future consumers.

## Design

Filtering occurs at each source collector's mapping boundary, before a `DetailedThermalReading` is emitted.

The SMC mapper will omit `TVDi` by exact, case-sensitive key. Other `TV..` keys remain eligible for existing classification and plausibility handling.

The IOHID mapper will normalize the product name by trimming surrounding whitespace and comparing case-insensitively. It will omit exactly these normalized products:

- `PMU tdev1`
- `PMU2 tdev1`
- `PMU2 tdev3`

The registry ID and enumeration index are deliberately excluded from matching because they can change across boots. Similar but valid products, including `PMU tdev3`, `PMU tdev2`, and `PMU2 tdev2`, remain visible.

Confirmed-unreliable sensors are silently omitted. They do not create detailed readings, user-visible warnings, or partial source status. They are known unusable channels rather than collection failures.

Existing generic plausibility behavior remains unchanged for other sensors. This change does not introduce a broad zero-degree lower bound and therefore does not suppress potentially legitimate cold-environment readings from unrelated sensor categories.

## Data Flow

1. The provider returns a raw SMC or IOHID record.
2. The source mapper checks the record's stable sensor identity.
3. A confirmed-unreliable identity returns no detailed reading.
4. All other records continue through the existing decoding, classification, warning, aggregation, and display paths.
5. Because both summary and advanced UI consume the cleaned detailed-reading collection, rejected sensors appear nowhere in either view.

## Testing

SMC mapper tests will prove:

- `TVDi` is omitted even when its payload decodes to a finite number.
- A neighboring heuristic temperature key remains emitted.

IOHID mapper tests will prove:

- Each confirmed-unreliable product is omitted.
- Matching is insensitive to case and surrounding whitespace.
- `PMU tdev3` and other similarly named valid products remain emitted.

The complete Swift test suite must continue to pass.

## Scope

This change only filters the four sensor identities confirmed by live telemetry. It does not rename CPU summary values, change temperature color bands, alter source preference, add runtime reliability persistence, or redesign Thermals Advanced.
