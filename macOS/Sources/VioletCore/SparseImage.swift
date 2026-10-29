import Foundation
import VioletNative

struct SparseChunk: Sendable {
    let type: UInt64
    let sourceOffset: UInt64
    let outputOffset: UInt64
    let length: UInt64
    let payloadSize: UInt64
    let fill: Data?
}

// Android Sparse v1: AOSP system/core/libsparse/sparse_format.h.
public struct SparseImage: Sendable {
    public let sourceURL: URL
    public let blockSize: UInt64
    public let expandedSize: UInt64
    public let materializedBytes: UInt64
    public let hasCRC: Bool
    public var fileSize: UInt64 { snapshot.size }
    public var chunkCount: Int { chunks.count }
    private let snapshot: FileSnapshot
    private let checksum: UInt32
    private let chunks: [SparseChunk]

    public static func isSparse(_ url: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: 4) ?? Data()
        guard data.count == 4 else { return false }
        return try data.integer(at: 0, bytes: 4) == 0xed26ff3a
    }

    public static func inspect(_ url: URL, control: WorkControl = WorkControl()) throws -> SparseImage {
        let snapshot = try FileSnapshot(url), input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.readExactly(offset: 0, count: 28, fileSize: snapshot.size)
        guard try header.integer(at: 0, bytes: 4) == 0xed26ff3a, try header.integer(at: 4, bytes: 2) == 1 else {
            throw InputError.invalid("不是支持的 Android Sparse v1 镜像。")
        }
        let headerSize = try header.integer(at: 8, bytes: 2), chunkHeader = try header.integer(at: 10, bytes: 2)
        let block = try header.integer(at: 12, bytes: 4), blocks = try header.integer(at: 16, bytes: 4)
        let count = try header.integer(at: 20, bytes: 4), checksum = UInt32(try header.integer(at: 24, bytes: 4))
        let expanded = try checkedMultiply(block, blocks)
        guard headerSize >= 28, headerSize <= snapshot.size, chunkHeader >= 12, block > 0, block <= 1024 * 1024,
              block % 4 == 0, count > 0, count <= 1_000_000, expanded > 0, expanded <= 1 << 40 else {
            throw InputError.invalid("Sparse 文件头参数无效或超过大小限制。")
        }
        var cursor = headerSize, output: UInt64 = 0, materialized: UInt64 = 0, chunks: [SparseChunk] = []
        for _ in 0..<count {
            try control.check()
            let data = try input.readExactly(offset: cursor, count: Int(chunkHeader), fileSize: snapshot.size)
            let type = try data.integer(at: 0, bytes: 2), chunkBlocks = try data.integer(at: 4, bytes: 4)
            let total = try data.integer(at: 8, bytes: 4), length = try checkedMultiply(chunkBlocks, block)
            guard total >= chunkHeader else { throw InputError.invalid("Sparse chunk 长度无效。") }
            let payloadSize = total - chunkHeader
            let source = try checkedAdd(cursor, chunkHeader), end = try checkedAdd(cursor, total)
            guard end <= snapshot.size else { throw InputError.invalid("Sparse chunk 已截断。") }
            let valid: Bool
            switch type {
            case 0xcac1: valid = payloadSize == length
            case 0xcac2: valid = payloadSize == 4
            case 0xcac3: valid = payloadSize == 0
            case 0xcac4: valid = payloadSize == 4 && chunkBlocks == 0
            default: valid = false
            }
            guard valid, output <= expanded, length <= expanded - output else { throw InputError.invalid("Sparse chunk 类型或展开范围无效。") }
            let fill = type == 0xcac2 || type == 0xcac4 ? try input.readExactly(offset: source, count: 4, fileSize: snapshot.size) : nil
            chunks.append(SparseChunk(type: type, sourceOffset: source, outputOffset: output, length: length, payloadSize: payloadSize, fill: fill))
            output += length; cursor = end
            if type == 0xcac1 || type == 0xcac2 { materialized = try checkedAdd(materialized, length) }
        }
        guard output == expanded, cursor == snapshot.size else { throw InputError.invalid("Sparse 块数、文件长度或尾部数据不一致。") }
        try snapshot.validate()
        return SparseImage(sourceURL: url, blockSize: block, expandedSize: expanded, materializedBytes: materialized,
                           hasCRC: checksum != 0 || chunks.contains { $0.type == 0xcac4 }, snapshot: snapshot, checksum: checksum, chunks: chunks)
    }

    public func expand(to destination: URL, control: WorkControl = WorkControl(),
                       progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL {
        let output = try AtomicOutput(destination)
        try output.handle.truncate(atOffset: expandedSize)
        var assigned = WrittenRanges()
        try apply(to: output.handle, assigned: &assigned, control: control, progress: progress)
        try control.check()
        return try output.commit()
    }

    /// Verify sparse checksums without materializing DONT_CARE regions. This
    /// lets physical package flashing retain sparse segment overlay semantics.
    public func validateContents(control: WorkControl = WorkControl()) throws {
        try snapshot.validate(); try control.check()
        guard hasCRC else { return }
        let input = try FileHandle(forReadingFrom: sourceURL); defer { try? input.close() }
        var crc: UInt32 = 0
        for chunk in chunks {
            try control.check()
            if chunk.type == 0xcac4 {
                guard UInt32(try chunk.fill!.integer(at: 0, bytes: 4)) == crc else { throw InputError.invalid("Sparse CRC32 chunk 不匹配。") }; continue
            }
            if chunk.type == 0xcac3 { crc = violet_crc32_zeros(crc, chunk.length); continue }
            var fill = Data()
            if let pattern = chunk.fill { fill = Data((0..<(1024 * 1024)).map { pattern[$0 % 4] }) }
            var done: UInt64 = 0
            while done < chunk.length {
                try control.check()
                let count = Int(min(1024 * 1024, chunk.length - done))
                let bytes = chunk.type == 0xcac1 ? try input.readExactly(offset: checkedAdd(chunk.sourceOffset, done), count: count, fileSize: snapshot.size) : Data(fill.prefix(count))
                crc = bytes.withUnsafeBytes { violet_crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }; done += UInt64(count)
            }
        }
        guard checksum == 0 || checksum == crc else { throw InputError.invalid("Sparse 整镜像 CRC32 不匹配。") }
        try control.check(); try snapshot.validate()
    }

    func apply(to output: FileHandle, assigned: inout WrittenRanges, control: WorkControl,
               progress: @escaping @Sendable (WorkProgress) -> Void) throws {
        try snapshot.validate()
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var crc: UInt32 = 0
        for chunk in chunks {
            try control.check()
            if chunk.type == 0xcac4 {
                guard UInt32(try chunk.fill!.integer(at: 0, bytes: 4)) == crc else { throw InputError.invalid("Sparse CRC32 chunk 校验失败：\(sourceURL.lastPathComponent)") }
            } else if chunk.type == 0xcac3 {
                if hasCRC { crc = violet_crc32_zeros(crc, chunk.length) }
            } else {
                var position: UInt64 = 0
                let zeroFill = chunk.type == 0xcac2 && chunk.fill == Data(count: 4)
                if zeroFill {
                    // FILL(0) is a real write. A DONT_CARE chunk is a hole.
                    // Check prior materialized data before retaining an empty hole.
                    for overlap in assigned.overlaps(chunk.outputOffset..<(chunk.outputOffset + chunk.length)) {
                        var at = overlap.lowerBound
                        while at < overlap.upperBound {
                            try control.check()
                            let count = Int(min(1024 * 1024, overlap.upperBound - at))
                            let old = try output.readExactly(offset: at, count: count, fileSize: expandedSize)
                            guard old.allSatisfy({ $0 == 0 }) else { throw InputError.invalid("Super 分段在零填充区域发生数据冲突。") }
                            at += UInt64(count)
                        }
                    }
                    if hasCRC { crc = violet_crc32_zeros(crc, chunk.length) }
                } else {
                    var fill = Data()
                    if let pattern = chunk.fill {
                        fill = Data(count: 1024 * 1024)
                        fill.withUnsafeMutableBytes { target in
                            let bytes = target.bindMemory(to: UInt8.self)
                            for index in bytes.indices { bytes[index] = pattern[index % 4] }
                        }
                    }
                    while position < chunk.length {
                        try control.check()
                        let count = Int(min(1024 * 1024, chunk.length - position))
                        let data = chunk.type == 0xcac1 ? try input.readExactly(offset: checkedAdd(chunk.sourceOffset, position), count: count, fileSize: fileSize) : Data(fill.prefix(count))
                        let at = chunk.outputOffset + position
                        for overlap in assigned.overlaps(at..<(at + UInt64(count))) {
                            let old = try output.readExactly(offset: overlap.lowerBound, count: Int(overlap.count), fileSize: expandedSize)
                            let start = Int(overlap.lowerBound - at)
                            guard old == data.subdata(in: start..<(start + old.count)) else {
                                throw InputError.invalid("Super 分段包含不同的数据写入同一区域，请检查运营商 / 版本。")
                            }
                        }
                        try output.seek(toOffset: at); try output.write(contentsOf: data)
                        if hasCRC { crc = data.withUnsafeBytes { violet_crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, data.count) } }
                        position += UInt64(count)
                        progress(WorkProgress("处理 \(sourceURL.lastPathComponent)", done: chunk.sourceOffset + min(position, chunk.payloadSize), total: fileSize))
                    }
                }
                if chunk.length > 0 { assigned.insert(chunk.outputOffset..<(chunk.outputOffset + chunk.length)) }
            }
            progress(WorkProgress("处理 \(sourceURL.lastPathComponent)", done: chunk.sourceOffset + chunk.payloadSize, total: fileSize))
        }
        if checksum != 0, checksum != crc { throw InputError.invalid("Sparse 镜像 CRC32 校验失败：\(sourceURL.lastPathComponent)") }
        try control.check(); try snapshot.validate()
    }
}

struct WrittenRanges {
    private var ranges: [Range<UInt64>] = []
    private func firstEnding(atOrAfter point: UInt64, inclusive: Bool) -> Int {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if inclusive ? ranges[middle].upperBound < point : ranges[middle].upperBound <= point { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    func overlaps(_ range: Range<UInt64>) -> [Range<UInt64>] {
        var index = firstEnding(atOrAfter: range.lowerBound, inclusive: false), result: [Range<UInt64>] = []
        while index < ranges.count, ranges[index].lowerBound < range.upperBound {
            result.append(max(range.lowerBound, ranges[index].lowerBound)..<min(range.upperBound, ranges[index].upperBound)); index += 1
        }
        return result
    }
    mutating func insert(_ range: Range<UInt64>) {
        let first = firstEnding(atOrAfter: range.lowerBound, inclusive: true)
        var end = first, lower = range.lowerBound, upper = range.upperBound
        while end < ranges.count, ranges[end].lowerBound <= upper {
            lower = min(lower, ranges[end].lowerBound); upper = max(upper, ranges[end].upperBound); end += 1
        }
        ranges.replaceSubrange(first..<end, with: [lower..<upper])
    }
}

public struct SuperVariant: Identifiable, Sendable {
    public let name: String
    public let segments: [URL]
    public var id: String { segments.map(\.path).joined(separator: "\n") }
}

public enum SuperSegments {
    private static let patterns = [#"^super\.(\d+)\.[^.]+\.(?:img|bin|raw|sparse)$"#, #"^super[_\-.]?(\d+)(?:\.(?:img|bin|raw|sparse))?$"#, #"^super\.(?:img|bin|raw|sparse)[_\-.](\d+)$"#]
    public static func sorted(_ urls: [URL]) throws -> [URL] {
        guard urls.count >= 2, urls.count <= 4096 else { throw InputError.invalid("请选择 2 至 4096 个同版本的 Super 分段。") }
        var entries: [(Int, URL)] = [], indices: Set<Int> = [], paths: Set<String> = []
        for url in urls {
            guard paths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { throw InputError.invalid("重复选择了同一个分段。") }
            let name = url.lastPathComponent, text = name as NSString
            var index: Int?
            for pattern in patterns {
                if let match = try NSRegularExpression(pattern: pattern, options: .caseInsensitive).firstMatch(in: name, range: NSRange(location: 0, length: text.length)) {
                    index = Int(text.substring(with: match.range(at: 1))); break
                }
            }
            guard let index else { throw InputError.invalid("无法识别分段编号：\(name)") }
            guard indices.insert(index).inserted else { throw InputError.invalid("分段编号 \(index) 重复，请选择同一运营商 / 版本的文件。") }
            entries.append((index, url))
        }
        entries.sort { $0.0 < $1.0 }
        let first = entries[0].0
        guard first == 0 || first == 1 else { throw InputError.invalid("Super 分段编号应从 0 或 1 开始。") }
        for (offset, item) in entries.enumerated() { guard item.0 == first + offset else { throw InputError.invalid("Super 分段不连续，缺少编号 \(first + offset)。") } }
        return entries.map(\.1)
    }

    public static func variants(for urls: [URL]) throws -> [SuperVariant] {
        guard let folder = urls.first?.deletingLastPathComponent(), urls.allSatisfy({ $0.deletingLastPathComponent() == folder }) else { return [] }
        guard let profile = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.lowercased() == "profile.xml" }) else { return [] }
        let size = try FileSnapshot(profile).size
        guard size <= 32 * 1024 * 1024 else { throw InputError.invalid("ProFile.xml 过大。") }
        let root = try FirmwareXML.parse(String(contentsOf: profile, encoding: .utf8))
        let mapping = Dictionary(urls.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let regex = try NSRegularExpression(pattern: #"^super(\d+)$"#, options: .caseInsensitive)
        var result: [SuperVariant] = [], seen: Set<String> = []
        for node in [root] + root.descendants {
            let attributes = node.attributes.compactMap { key, value -> (Int, String)? in
                let text = key as NSString
                guard let match = regex.firstMatch(in: key, range: NSRange(location: 0, length: text.length)), let index = Int(text.substring(with: match.range(at: 1))) else { return nil }
                return (index, value)
            }.sorted { $0.0 < $1.0 }
            guard attributes.count >= 2 else { continue }
            let candidates = attributes.compactMap { item in mapping[item.1.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last!.lowercased()] }
            guard candidates.count == attributes.count, let ordered = try? sorted(candidates) else { continue }
            let variant = SuperVariant(name: node.attribute("text") ?? node.attribute("id") ?? "版本 \(result.count + 1)", segments: ordered)
            if seen.insert(variant.id).inserted { result.append(variant) }
        }
        return result
    }

    public static func merge(_ urls: [URL], to destination: URL, control: WorkControl = WorkControl(),
                             progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL {
        let ordered = try sorted(urls)
        let snapshots = try ordered.map(FileSnapshot.init)
        guard snapshots.allSatisfy({ $0.size > 0 }) else { throw InputError.invalid("Super 分段为空。") }
        let kinds = try ordered.map(SparseImage.isSparse)
        guard kinds.allSatisfy({ $0 == kinds[0] }) else { throw InputError.invalid("不能混合合并 Sparse 和 Raw 分段。") }
        let total = try snapshots.reduce(UInt64(0)) { try checkedAdd($0, $1.size) }
        guard !ordered.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() }) else { throw InputError.invalid("输出不能覆盖源分段。") }
        var done: UInt64 = 0
        if kinds[0] {
            let images = try ordered.map { try SparseImage.inspect($0, control: control) }
            guard images.allSatisfy({ $0.blockSize == images[0].blockSize && $0.expandedSize == images[0].expandedSize }) else { throw InputError.invalid("Super Sparse 分段的块大小或展开布局不同。") }
            let output = try AtomicOutput(destination)
            try output.handle.truncate(atOffset: images[0].expandedSize)
            var assigned = WrittenRanges()
            for image in images {
                let base = done
                try image.apply(to: output.handle, assigned: &assigned, control: control) { item in progress(WorkProgress(item.label, done: base + item.done, total: total)) }
                done += image.fileSize
            }
            try control.check()
            return try output.commit()
        }
        guard total <= 1 << 40 else { throw InputError.invalid("Raw 合并大小超过 1 TiB 限制。") }
        let output = try AtomicOutput(destination)
        for snapshot in snapshots {
            try snapshot.validate()
            let input = try FileHandle(forReadingFrom: snapshot.url)
            defer { try? input.close() }
            var position: UInt64 = 0
            while position < snapshot.size {
                try control.check()
                let count = Int(min(1024 * 1024, snapshot.size - position))
                let data = try input.readExactly(offset: position, count: count, fileSize: snapshot.size)
                try output.handle.write(contentsOf: data); position += UInt64(count)
                progress(WorkProgress("拼接 \(snapshot.url.lastPathComponent)", done: done + position, total: total))
            }
            try snapshot.validate(); done += snapshot.size
        }
        try control.check()
        return try output.commit()
    }
}
