import Foundation
import SQLite3

enum GraphFailure: LocalizedError {
    case missing
    case permission
    case busy
    case schema
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missing: "Graph Database Not Found"
        case .permission: "macOS Restricts Access to the Database"
        case .busy: "Database Temporarily Busy"
        case .schema: "Unsupported Graph Schema"
        case .unreadable: "Could Not Read SQLite Database"
        }
    }
}

// The handle and statements stay on the task that opens them.
final class SQLiteDatabase {
    enum Parameter {
        case integer(Int64)
        case real(Double)
        case null
        case text(String)
    }

    private let handle: OpaquePointer

    init(url: URL?, demoSQL: String = DemoGraph.sql) throws {
        try Task.checkCancellation()
        let path = url?.resolvingSymlinksInPath().path(percentEncoded: false) ?? ":memory:"
        if let url {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path)
                let file = try FileHandle(forReadingFrom: url)
                try file.close()
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain {
                    switch CocoaError.Code(rawValue: error.code) {
                    case .fileReadNoSuchFile, .fileNoSuchFile: throw GraphFailure.missing
                    case .fileReadNoPermission: throw GraphFailure.permission
                    default: break
                    }
                }
                throw GraphFailure.unreadable
            }
        }

        var opened: OpaquePointer?
        let flags = url == nil ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            sqlite3_close(opened)
            throw Self.failure(code)
        }
        do {
            try Self.configure(opened, seed: url == nil ? demoSQL : nil)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        handle = opened
    }

    private static func configure(_ handle: OpaquePointer, seed: String?) throws {
        sqlite3_busy_timeout(handle, 800)
        sqlite3_progress_handler(handle, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)

        let searchCode = sqlite3_create_function_v2(
            handle, "iknow_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_DIRECTONLY,
            nil, { context, _, args in
                guard let args, let value = sqlite3_value_text(args[0]), let pattern = sqlite3_value_text(args[1])
                else {
                    sqlite3_result_int(context, 0)
                    return
                }
                let text = SQLiteDatabase.decodeText(value, length: sqlite3_value_bytes(args[0]))
                let needle = SQLiteDatabase.decodeText(pattern, length: sqlite3_value_bytes(args[1]))
                let match = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                sqlite3_result_int(context, match ? 1 : 0)
            }, nil, nil, nil
        )
        if searchCode != SQLITE_OK { throw Self.failure(searchCode) }

        try execute("PRAGMA trusted_schema = OFF; PRAGMA temp_store = MEMORY;", on: handle)
        if let seed {
            try execute(seed, on: handle)
        }
        try execute("PRAGMA query_only = ON; BEGIN;", on: handle)
    }

    deinit {
        sqlite3_close(handle)
    }

    private static func execute(_ sql: String, on handle: OpaquePointer) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        if code != SQLITE_OK { throw Self.failure(code) }
    }

    func query<Value>(
        _ sql: String, _ parameters: [Parameter] = [], map: (OpaquePointer) throws -> Value
    ) throws -> [Value] {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else { throw Self.failure(prepareCode) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == parameters.count else { throw GraphFailure.schema }

        for (offset, parameter) in parameters.enumerated() {
            let position = Int32(offset + 1)
            let code: Int32
            switch parameter {
            case .integer(let value):
                code = sqlite3_bind_int64(statement, position, value)
            case .real(let value):
                code = sqlite3_bind_double(statement, position, value)
            case .null:
                code = sqlite3_bind_null(statement, position)
            case .text(let value):
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let length = UInt64(value.utf8.count)
                code = value.withCString { sqlite3_bind_text64(statement, position, $0, length, transient, UInt8(SQLITE_UTF8)) }
            }
            if code != SQLITE_OK { throw Self.failure(code) }
        }

        var results: [Value] = []
        while true {
            let code = sqlite3_step(statement)
            switch code {
            case SQLITE_ROW: results.append(try map(statement))
            case SQLITE_DONE: return results
            default: throw Self.failure(code)
            }
        }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(row, column) else { return nil }
        return decodeText(bytes, length: sqlite3_column_bytes(row, column))
    }

    private static func decodeText(_ bytes: UnsafePointer<UInt8>, length: Int32) -> String {
        String(decoding: UnsafeBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
    }

    static func integer(_ row: OpaquePointer, _ column: Int32) -> Int64? {
        guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(row, column)
    }

    static func number(_ row: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(row, column)
        return value.isFinite ? value : nil
    }

    private static func failure(_ code: Int32) -> any Error {
        switch code & 0xff {
        case SQLITE_INTERRUPT: CancellationError()
        case SQLITE_BUSY, SQLITE_LOCKED: GraphFailure.busy
        case SQLITE_PERM, SQLITE_AUTH: GraphFailure.permission
        case SQLITE_ERROR, SQLITE_SCHEMA: GraphFailure.schema
        default: GraphFailure.unreadable
        }
    }
}
