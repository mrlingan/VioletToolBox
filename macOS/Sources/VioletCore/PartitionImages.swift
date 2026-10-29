import Foundation

public struct PartitionImageInput: Sendable {
    public let sourceURL: URL
    public let expandedSize: UInt64
    public var isSparse: Bool { sparse != nil }
    private let snapshot: FileSnapshot
    private let sparse: SparseImage?
    public static func open(_ url: URL, for partition: DevicePartition, control: WorkControl = WorkControl()) throws -> PartitionImageInput {
        try control.check()
        let snapshot = try FileSnapshot(url), handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard snapshot.size > 0 else { throw InputError.invalid("镜像文件为空。") }
        let header = try handle.readExactly(offset: 0, count: Int(min(4, snapshot.size)), fileSize: snapshot.size)
        let sparse = header == Data([0x3a,0xff,0x26,0xed]) ? try SparseImage.inspect(url, control: control) : nil
        let size = sparse?.expandedSize ?? snapshot.size
        guard size > 0, size <= partition.size else { throw InputError.invalid("\(partition.name)：镜像展开后 \(size) bytes，不符合分区容量 \(partition.size)。") }
        try snapshot.validate()
        return PartitionImageInput(sourceURL: url, expandedSize: size, snapshot: snapshot, sparse: sparse)
    }
    public func validate() throws { try snapshot.validate() }
    public func copySource(to target: URL, control: WorkControl, progress: @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL {
        try control.check(); try snapshot.validate()
        let input = try FileHandle(forReadingFrom: sourceURL), output = try AtomicOutput(target)
        defer { try? input.close() }
        var done: UInt64 = 0
        while done < snapshot.size {
            try control.check()
            let bytes = try input.readExactly(offset: done, count: Int(min(1024 * 1024, snapshot.size - done)), fileSize: snapshot.size)
            try output.handle.write(contentsOf: bytes); done += UInt64(bytes.count)
            progress(WorkProgress(sourceURL.lastPathComponent, done: done, total: snapshot.size))
        }
        try control.check(); try snapshot.validate(); return try output.commit()
    }
    public func rawFile(in directory: URL, control: WorkControl, progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL {
        try control.check(); try snapshot.validate()
        guard let sparse else { return sourceURL }
        return try sparse.expand(to: directory.appendingPathComponent("expanded-" + UUID().uuidString + ".img"), control: control, progress: progress)
    }
}

public struct BlockGeometry: Identifiable, Sendable {
    public let name: String
    public let lun: UInt64
    public let sectorSize: UInt64
    public let totalSectors: UInt64
    public var id: String { name }
    public var byteCount: UInt64 { sectorSize * totalSectors }
    public var path: String { "/dev/block/" + name }
    public static let probe = """
    [ "$(id -u)" = 0 ] || exit 77
    printf 'VIOLET_BLOCKS_V1\\n'
    for directory in /sys/class/block/*; do
      name=${directory##*/}
      case "$name" in
        sd[a-z]) ;;
        mmcblk*) number=${name#mmcblk}; case "$number" in ''|*[!0-9]*) continue;; esac;;
        *) continue;;
      esac
      [ -b "/dev/block/$name" ] || continue
      sector=$(cat "$directory/queue/logical_block_size") || exit 74
      blocks=$(cat "$directory/size") || exit 74
      device=$(readlink -f "$directory/device") || device=unknown
      printf '%s\\t%s\\t%s\\t%s\\n' "$name" "$sector" "$blocks" "$device"
    done
    """
    public static func parse(_ text: String) throws -> [BlockGeometry] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.first == "VIOLET_BLOCKS_V1", lines.count <= 257 else { throw InputError.invalid("物理块设备响应无效。") }
        var result: [BlockGeometry] = [], names: Set<String> = []
        for line in lines.dropFirst() {
            let f = line.components(separatedBy: "\t")
            guard f.count == 4, f[0].range(of: "^(sd[a-z]|mmcblk[0-9]+)$", options: .regularExpression) != nil,
                  names.insert(f[0]).inserted, let sector = UInt64(f[1]), [512,1024,2048,4096,8192,16384,32768,65536].contains(sector),
                  let blocks = UInt64(f[2]) else { throw InputError.invalid("物理块设备几何信息无效。") }
            let bytes = try checkedMultiply(blocks, 512)
            guard bytes % sector == 0, bytes / sector >= 6 else { continue }
            var lun: UInt64
            if f[0].hasPrefix("sd"), let letter = f[0].utf8.last { lun = UInt64(letter - 97) }
            else { lun = UInt64(f[0].dropFirst(6)) ?? 0 }
            let regex = try NSRegularExpression(pattern: ":([0-9]+)(?:/|$)")
            if let match = regex.matches(in: f[3], range: NSRange(f[3].startIndex..., in: f[3])).last,
               let range = Range(match.range(at: 1), in: f[3]), let found = UInt64(f[3][range]) { lun = found }
            guard lun <= 255 else { throw InputError.invalid("存储 LUN 编号无效。") }
            result.append(BlockGeometry(name: f[0], lun: lun, sectorSize: sector, totalSectors: bytes / sector))
        }
        return result.sorted { $0.lun == $1.lun ? $0.name < $1.name : $0.lun < $1.lun }
    }
    public func readArguments(lba: UInt64, sectors: UInt64) throws -> [String] {
        guard lba < totalSectors, sectors > 0, sectors <= totalSectors - lba,
              try checkedMultiply(sectorSize, sectors) <= 64 * 1024 * 1024 else { throw InputError.invalid("GPT 读取范围无效。") }
        _ = try PartitionCommands.blockPath(path)
        return PartitionCommands.execOut("[ \"$(id -u)\" = 0 ] && dd if=\(Input.remoteQuote(path)) bs=\(sectorSize) skip=\(lba) count=\(sectors) 2>/dev/null")
    }
}
