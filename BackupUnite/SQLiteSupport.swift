import Foundation
import SQLite3

enum SQLiteValue: Hashable, Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    var int: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }

    var string: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var stable: String {
        switch self {
        case let .integer(value): "i:\(value)"
        case let .real(value): "r:\(value)"
        case let .text(value): "t:\(value)"
        case let .blob(value): "b:\(value.base64EncodedString())"
        case .null: "n:"
        }
    }
}

typealias SQLiteRow = [String: SQLiteValue]

extension Dictionary where Key == String, Value == SQLiteValue {
    func int(_ key: String) throws -> Int64 {
        guard let value = self[key]?.int else { throw MergeEngineError.invalidRow("\(key) is not an integer") }
        return value
    }

    func optionalInt(_ key: String) -> Int64? { self[key]?.int }

    func text(_ key: String) throws -> String {
        guard let value = self[key]?.string else { throw MergeEngineError.invalidRow("\(key) is not text") }
        return value
    }

    func optionalText(_ key: String) -> String? { self[key]?.string }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(handle)
            handle = nil
            throw MergeEngineError.sqlite(message)
        }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, values: [SQLiteValue] = []) throws {
        guard let handle else { throw MergeEngineError.sqlite("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MergeEngineError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MergeEngineError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func query(_ sql: String, values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        guard let handle else { throw MergeEngineError.sqlite("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MergeEngineError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var result: [SQLiteRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw MergeEngineError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
            var row: SQLiteRow = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let pointer = sqlite3_column_blob(statement, index) {
                        row[name] = .blob(Data(bytes: pointer, count: count))
                    } else {
                        row[name] = .blob(Data())
                    }
                default:
                    row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }

    func allRows(in table: String) throws -> [SQLiteRow] {
        try query("SELECT * FROM \(Self.quote(table))")
    }

    func insert(rows: [SQLiteRow], into table: String) throws {
        guard let first = rows.first else { return }
        guard let handle else { throw MergeEngineError.sqlite("database closed") }
        let columns = first.keys.sorted()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
        let sql = "INSERT INTO \(Self.quote(table)) (\(columns.map(Self.quote).joined(separator: ","))) VALUES (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MergeEngineError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            try bind(columns.map { row[$0] ?? .null }, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw MergeEngineError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
            case let .real(number): result = sqlite3_bind_double(statement, index, number)
            case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case let .blob(data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw MergeEngineError.sqlite("could not bind parameter \(index)") }
        }
    }

    static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
