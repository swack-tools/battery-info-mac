import Darwin
import Foundation

public enum ProbeArgumentError: Error, Equatable, CustomStringConvertible {
    case mutuallyExclusiveFormats
    case missingValue(String)
    case invalidPositiveInteger(option: String, value: String)
    case unknownOption(String)

    public var description: String {
        switch self {
        case .mutuallyExclusiveFormats:
            return "--json and --jsonl are mutually exclusive"
        case let .missingValue(option):
            return "\(option) requires a value"
        case let .invalidPositiveInteger(option, value):
            return "\(option) requires a positive integer, got '\(value)'"
        case let .unknownOption(option):
            return "unknown option '\(option)'"
        }
    }
}

public struct ProbeOptions: Equatable {
    public enum Format: Equatable {
        case human
        case json
        case jsonLines
    }

    public var format: Format
    public var samples: Int
    public var intervalMilliseconds: Int
    public var raw: Bool
    public var help: Bool

    public init(
        format: Format,
        samples: Int,
        intervalMilliseconds: Int,
        raw: Bool,
        help: Bool
    ) {
        self.format = format
        self.samples = samples
        self.intervalMilliseconds = intervalMilliseconds
        self.raw = raw
        self.help = help
    }

    public static let `default` = ProbeOptions(
        format: .human,
        samples: 1,
        intervalMilliseconds: 1000,
        raw: false,
        help: false
    )

    public static func repeated(samples: Int, interval: Int) -> ProbeOptions {
        ProbeOptions(
            format: .human,
            samples: samples,
            intervalMilliseconds: interval,
            raw: false,
            help: false
        )
    }

    public static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var options = ProbeOptions.default
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                guard options.format != .jsonLines else {
                    throw ProbeArgumentError.mutuallyExclusiveFormats
                }
                options.format = .json
            case "--jsonl":
                guard options.format != .json else {
                    throw ProbeArgumentError.mutuallyExclusiveFormats
                }
                options.format = .jsonLines
            case "--samples":
                let value = try nextValue(for: argument, arguments: arguments, index: &index)
                options.samples = try positiveInteger(option: argument, value: value)
            case "--interval":
                let value = try nextValue(for: argument, arguments: arguments, index: &index)
                options.intervalMilliseconds = try positiveInteger(option: argument, value: value)
            case "--raw":
                options.raw = true
            case "--help", "-h":
                options.help = true
            default:
                throw ProbeArgumentError.unknownOption(argument)
            }
            index += 1
        }

        return options
    }

    public static let usage = """
    Usage: sudo thermal-probe [options]

      --json             Emit one complete JSON capture
      --jsonl            Stream tagged JSON Lines records
      --samples N        Capture N samples (default: 1)
      --interval MS      Milliseconds between sample starts (default: 1000)
      --raw              Include undecoded and non-temperature records
      --help, -h         Show this help
    """

    private static func nextValue(
        for option: String,
        arguments: [String],
        index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ProbeArgumentError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func positiveInteger(option: String, value: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw ProbeArgumentError.invalidPositiveInteger(option: option, value: value)
        }
        return parsed
    }
}

public enum RuntimeDecision: Equatable {
    case showHelp
    case collect
    case exit(Int32)

    public static func evaluate(options: ProbeOptions, effectiveUserID: uid_t) -> RuntimeDecision {
        if options.help {
            return .showHelp
        }
        guard effectiveUserID == 0 else {
            return .exit(77)
        }
        return .collect
    }
}
