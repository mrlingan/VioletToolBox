import Foundation

/// Bounded unsigned arithmetic for Firehose disk-relative addresses. Does not
/// invoke a shell, JavaScript engine, Python, or a general expression runtime.
public enum EDLExpression {
    public static func value(_ expression: String, geometry: EDLGeometry) throws -> UInt64 {
        var parser = Parser(text: Array(expression.utf8), geometry: geometry)
        guard parser.text.count <= 256 else { throw InputError.invalid("Firehose 表达式过长。") }
        let value = try parser.sum(depth: 0); parser.spaces()
        guard parser.position == parser.text.count else { throw InputError.invalid("未支持的 Firehose 表达式：\(expression)") }
        return value
    }
    public static func patchValue(_ expression: String, bytes: UInt64, geometry: EDLGeometry) throws -> String {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [1,2,4,8].contains(bytes) else { throw InputError.invalid("Patch 宽度仅支持 1 / 2 / 4 / 8 bytes。") }
        if text.uppercased().hasPrefix("CRC32("), text.hasSuffix(")") {
            let inner = String(text.dropFirst(6).dropLast())
            var depth = 0, comma: String.Index?
            for index in inner.indices {
                if inner[index] == "(" { depth += 1 }
                if inner[index] == ")" { depth -= 1 }
                if inner[index] == "," && depth == 0 { guard comma == nil else { throw InputError.invalid("CRC32 参数过多。") }; comma = index }
            }
            guard bytes >= 4, let comma, depth == 0 else { throw InputError.invalid("CRC32 需要两个参数和至少 4-byte 目标。") }
            let sector = try value(String(inner[..<comma]), geometry: geometry), count = try value(String(inner[inner.index(after: comma)...]), geometry: geometry)
            let offset = try checkedMultiply(sector, geometry.sectorSize)
            guard count > 0, offset < geometry.byteCount, count <= geometry.byteCount - offset else { throw InputError.invalid("Patch CRC32 读取范围越界。") }
            return "CRC32(\(sector),\(count))"
        }
        let number = try value(text, geometry: geometry)
        guard bytes == 8 || number < (UInt64(1) << (bytes * 8)) else { throw InputError.invalid("Patch 值超出字段宽度。") }
        return String(number)
    }
    private struct Parser {
        let text: [UInt8]
        let geometry: EDLGeometry
        var position = 0
        mutating func spaces() { while position < text.count && [9,10,13,32].contains(text[position]) { position += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            spaces(); guard position < text.count, text[position] == byte else { return false }; position += 1; return true
        }
        mutating func sum(depth: Int) throws -> UInt64 {
            var result = try product(depth: depth)
            while true {
                if take(43) { result = try checkedAdd(result, product(depth: depth)) }
                else if take(45) { let rhs = try product(depth: depth); guard rhs <= result else { throw InputError.invalid("Firehose 表达式下溢。") }; result -= rhs }
                else { return result }
            }
        }
        mutating func product(depth: Int) throws -> UInt64 {
            var result = try atom(depth: depth)
            while true {
                if take(42) { result = try checkedMultiply(result, atom(depth: depth)) }
                else if take(47) { let rhs = try atom(depth: depth); guard rhs > 0 else { throw InputError.invalid("Firehose 表达式除零。") }; result /= rhs }
                else if take(37) { let rhs = try atom(depth: depth); guard rhs > 0 else { throw InputError.invalid("Firehose 表达式余数除零。") }; result %= rhs }
                else { return result }
            }
        }
        mutating func atom(depth: Int) throws -> UInt64 {
            guard depth < 32 else { throw InputError.invalid("Firehose 表达式嵌套过深。") }
            spaces()
            if take(43) { return try atom(depth: depth + 1) }
            if take(40) { let value = try sum(depth: depth + 1); guard take(41) else { throw InputError.invalid("Firehose 表达式括号不完整。") }; return value }
            let start = position
            while position < text.count && ((48...57).contains(text[position]) || (65...90).contains(text[position]) || (97...122).contains(text[position]) || text[position] == 95) { position += 1 }
            let token = String(decoding: text[start..<position], as: UTF8.self).uppercased(), result: UInt64
            if token == "NUM_DISK_SECTORS" { result = geometry.totalSectors }
            else if token == "SECTOR_SIZE_IN_BYTES" { result = geometry.sectorSize }
            else if token.hasPrefix("0X"), let number = UInt64(token.dropFirst(2), radix: 16) { result = number }
            else if let number = UInt64(token) { result = number }
            else { throw InputError.invalid("无效 Firehose 整数或变量：\(token)") }
            if position < text.count && text[position] == 46 { position += 1 }
            return result
        }
    }
}
