import Foundation
import CoreFoundation

// A native archive can mix named and positional serialization. Keep the
// template's field order and unchanged scalar spellings instead of sorting keys.
indirect enum NativeJSON {
    case object([(String, NativeJSON)])
    case array([NativeJSON])
    case scalar(String)

    static func parse(_ data: Data) throws -> NativeJSON {
        var parser = Parser(bytes: Array(data))
        let node = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw ExportFailure("Unexpected native JSON trailer.") }
        return node
    }

    func encode(_ value: Any) throws -> Data {
        Data(try text(value).utf8)
    }

    private func text(_ value: Any) throws -> String {
        if let dict = value as? [String: Any] {
            let fields: [(String, NativeJSON)]
            if case .object(let original) = self { fields = original } else { fields = [] }
            let known = Set(fields.map { $0.0 })
            let ordered = fields.filter { dict[$0.0] != nil } + dict.keys.filter { !known.contains($0) }.sorted().map { ($0, NativeJSON.scalar("null")) }
            return "{" + (try ordered.map { key, layout in
                let encodedKey = try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                return String(decoding: encodedKey, as: UTF8.self) + ":" + (try layout.text(dict[key]!))
            }).joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            let original: [NativeJSON]
            if case .array(let nodes) = self { original = nodes } else { original = [] }
            return "[" + (try array.enumerated().map { index, item in
                let layout = index < original.count ? original[index] : original.first ?? .scalar("null")
                return try layout.text(item)
            }).joined(separator: ",") + "]"
        }
        var originalToken: String?
        if case .scalar(let token) = self { originalToken = token }
        if let token = originalToken,
           let original = try? JSONSerialization.jsonObject(with: Data(token.utf8), options: .fragmentsAllowed),
           let object = value as? NSObject, let old = original as? NSObject,
           CFGetTypeID(object) == CFGetTypeID(old), object.isEqual(old) {
            return token
        }
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        var result = String(decoding: encoded, as: UTF8.self)
        if let token = originalToken, let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), !token.hasPrefix("\""),
           token.contains(".") || token.lowercased().contains("e"),
           !result.contains("."), !result.lowercased().contains("e") {
            result += ".0"
        }
        return result
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw ExportFailure("Invalid native JSON structure.") }
            index += 1
        }
        mutating func stringToken() throws -> String {
            whitespace()
            let start = index
            try consume(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return String(decoding: bytes[start..<index], as: UTF8.self) }
                if byte == 92 { index += 1 }
            }
            throw ExportFailure("Unterminated native JSON string.")
        }
        mutating func value(depth: Int) throws -> NativeJSON {
            whitespace()
            guard depth < 256, index < bytes.count else { throw ExportFailure("Invalid native JSON nesting.") }
            if bytes[index] == 123 {
                index += 1; whitespace()
                var fields: [(String, NativeJSON)] = []
                if index < bytes.count, bytes[index] == 125 { index += 1; return .object(fields) }
                while true {
                    let token = try stringToken()
                    guard let name = try JSONSerialization.jsonObject(with: Data(token.utf8), options: .fragmentsAllowed) as? String else { throw ExportFailure("Invalid native JSON key.") }
                    try consume(58)
                    fields.append((name, try value(depth: depth + 1)))
                    whitespace()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return .object(fields) }
                    try consume(44)
                }
            }
            if bytes[index] == 91 {
                index += 1; whitespace()
                var nodes: [NativeJSON] = []
                if index < bytes.count, bytes[index] == 93 { index += 1; return .array(nodes) }
                while true {
                    nodes.append(try value(depth: depth + 1)); whitespace()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return .array(nodes) }
                    try consume(44)
                }
            }
            if bytes[index] == 34 { return .scalar(try stringToken()) }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw ExportFailure("Invalid native JSON scalar.") }
            return .scalar(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }
}
