import Foundation

public enum CaptureAggregator {
    public static func aggregate(_ samples: [ThermalSample]) -> [SensorAggregate] {
        struct Bucket {
            var reading: Reading
            var values: [Double]
        }

        var buckets: [String: Bucket] = [:]
        for sample in samples {
            for reading in sample.sources.flatMap(\.readings) {
                guard let value = reading.number else { continue }
                let key = [reading.source, reading.identifier, reading.kind.rawValue]
                    .joined(separator: "\u{1f}")
                if var bucket = buckets[key] {
                    bucket.values.append(value)
                    buckets[key] = bucket
                } else {
                    buckets[key] = Bucket(reading: reading, values: [value])
                }
            }
        }

        return buckets.values.map { bucket in
            let values = bucket.values
            return SensorAggregate(
                source: bucket.reading.source,
                identifier: bucket.reading.identifier,
                label: bucket.reading.label,
                category: bucket.reading.category,
                kind: bucket.reading.kind,
                unit: bucket.reading.unit,
                minimum: values.min() ?? 0,
                average: values.reduce(0, +) / Double(values.count),
                maximum: values.max() ?? 0,
                delta: (values.last ?? 0) - (values.first ?? 0),
                sampleCount: values.count
            )
        }.sorted {
            if $0.source == $1.source { return $0.identifier < $1.identifier }
            return $0.source < $1.source
        }
    }

    public static func summarize(sample: ThermalSample) -> [SensorSummary] {
        var grouped: [ReadingCategory: [Double]] = [:]
        for reading in sample.sources.flatMap(\.readings)
            where reading.kind == .temperature && reading.classification == .known {
            guard let value = reading.number else { continue }
            grouped[reading.category, default: []].append(value)
        }

        return ReadingCategory.allCases.compactMap { category in
            guard let values = grouped[category], !values.isEmpty else { return nil }
            return SensorSummary(
                category: category,
                minimum: values.min() ?? 0,
                average: values.reduce(0, +) / Double(values.count),
                maximum: values.max() ?? 0,
                count: values.count
            )
        }
    }
}
