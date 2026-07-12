import Darwin
import Foundation

enum DynamicSystemLibraryError: Error, Equatable, CustomStringConvertible {
    case libraryUnavailable(source: String, path: String, detail: String)
    case symbolUnavailable(source: String, symbol: String, detail: String)

    var description: String {
        switch self {
        case let .libraryUnavailable(source, path, detail):
            return "\(source) library \(path) is unavailable: \(detail)"
        case let .symbolUnavailable(source, symbol, detail):
            return "\(source) symbol \(symbol) is unavailable: \(detail)"
        }
    }
}

protocol DynamicLibraryBackend: AnyObject {
    func open(path: String?, flags: Int32) -> UnsafeMutableRawPointer?
    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer?
    func close(handle: UnsafeMutableRawPointer)
    func errorMessage() -> String
}

final class DarwinDynamicLibraryBackend: DynamicLibraryBackend {
    func open(path: String?, flags: Int32) -> UnsafeMutableRawPointer? {
        dlerror()
        return dlopen(path, flags)
    }

    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer? {
        dlerror()
        return dlsym(handle, name)
    }

    func close(handle: UnsafeMutableRawPointer) {
        dlclose(handle)
    }

    func errorMessage() -> String {
        guard let error = dlerror() else { return "not found" }
        return String(cString: error)
    }
}

final class DynamicSystemLibrary: @unchecked Sendable {
    private let source: String
    private let pathDescription: String
    private let backend: any DynamicLibraryBackend
    private let handle: UnsafeMutableRawPointer
    private let symbolLock = NSLock()
    private var symbols: [String: Result<UnsafeMutableRawPointer, DynamicSystemLibraryError>] = [:]

    init(
        source: String,
        path: String?,
        backend: any DynamicLibraryBackend = DarwinDynamicLibraryBackend()
    ) throws {
        self.source = source
        pathDescription = path ?? "process image"
        self.backend = backend
        guard let handle = backend.open(path: path, flags: RTLD_NOW | RTLD_LOCAL) else {
            throw DynamicSystemLibraryError.libraryUnavailable(
                source: source,
                path: pathDescription,
                detail: backend.errorMessage()
            )
        }
        self.handle = handle
    }

    deinit {
        backend.close(handle: handle)
    }

    func rawSymbol(named name: String) throws -> UnsafeMutableRawPointer {
        symbolLock.lock()
        defer { symbolLock.unlock() }
        if let result = symbols[name] {
            return try result.get()
        }
        guard let symbol = backend.symbol(handle: handle, name: name) else {
            let error = DynamicSystemLibraryError.symbolUnavailable(
                source: source,
                symbol: name,
                detail: backend.errorMessage()
            )
            symbols[name] = .failure(error)
            throw error
        }
        symbols[name] = .success(symbol)
        return symbol
    }

    func resolve<T>(_ name: String, as type: T.Type = T.self) throws -> T {
        _ = type
        return unsafeBitCast(try rawSymbol(named: name), to: T.self)
    }
}
