import Darwin
import Foundation

public protocol ProbeClock: AnyObject {
    var wallNow: Date { get }
    var monotonicNow: TimeInterval { get }
    func sleep(milliseconds: Int)
}

public final class SystemProbeClock: ProbeClock {
    public init() {}

    public var wallNow: Date { Date() }
    public var monotonicNow: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        usleep(useconds_t(milliseconds) * 1_000)
    }
}

public struct CollectionContext {
    public let clock: any ProbeClock
    public let includeRaw: Bool

    public init(clock: any ProbeClock, includeRaw: Bool) {
        self.clock = clock
        self.includeRaw = includeRaw
    }
}

public protocol ThermalCollector {
    var source: String { get }
    func collect(context: CollectionContext) -> SourceResult
}

public enum CollectorRunner {
    public static func run(
        collectors: [any ThermalCollector],
        context: CollectionContext
    ) -> [SourceResult] {
        collectors.map { $0.collect(context: context) }
    }
}

public extension SourceResult {
    static func completed(
        source: String,
        startedAt: Date,
        durationMilliseconds: Double,
        readings: [Reading],
        warnings: [String] = [],
        capabilities: [String: JSONValue] = [:]
    ) -> SourceResult {
        SourceResult(
            source: source,
            status: warnings.isEmpty ? .success : .partial,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            readings: readings,
            warnings: warnings,
            error: nil,
            capabilities: capabilities
        )
    }

    static func failed(
        source: String,
        startedAt: Date,
        durationMilliseconds: Double,
        code: String,
        message: String,
        warnings: [String] = [],
        capabilities: [String: JSONValue] = [:]
    ) -> SourceResult {
        SourceResult(
            source: source,
            status: .failed,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            readings: [],
            warnings: warnings,
            error: SourceError(code: code, message: message),
            capabilities: capabilities
        )
    }

    static func unavailable(
        source: String,
        startedAt: Date,
        durationMilliseconds: Double,
        code: String,
        message: String,
        capabilities: [String: JSONValue] = [:]
    ) -> SourceResult {
        SourceResult(
            source: source,
            status: .unavailable,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            readings: [],
            warnings: [],
            error: SourceError(code: code, message: message),
            capabilities: capabilities
        )
    }

    static func timedOut(
        source: String,
        startedAt: Date,
        durationMilliseconds: Double,
        message: String,
        capabilities: [String: JSONValue] = [:]
    ) -> SourceResult {
        SourceResult(
            source: source,
            status: .timedOut,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            readings: [],
            warnings: [],
            error: SourceError(code: "timeout", message: message),
            capabilities: capabilities
        )
    }
}
