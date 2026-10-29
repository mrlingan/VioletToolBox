import Foundation

public struct DevicePartition: Identifiable, Sendable {
    public let name: String
    public let size: UInt64
    public let type: String
    public let blockPath: String?
    public var id: String { name }
    public init(name: String, size: UInt64, type: String = "raw", blockPath: String? = nil) throws {
        guard name.utf8.count <= 128, size > 0, size <= UInt64(Int64.max) else { throw InputError.invalid("分区名称或大小无效。") }
        self.name = try Input.partition(name); self.size = size; self.type = type
        if let blockPath { _ = try PartitionCommands.blockPath(blockPath) }
        self.blockPath = blockPath
    }
    public var isBaseband: Bool { PartitionCommands.basebandNames.contains(PartitionCommands.withoutSlot(name)) }
    public var isUserData: Bool { ["userdata","metadata"].contains(PartitionCommands.withoutSlot(name)) }
}

public enum PartitionCommands {
    public static let basebandNames: Set<String> = ["persist","modemst1","modemst2","fsg","fsc","oplusdycnvbk","oplusstanvbk"]
    public static func withoutSlot(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.hasSuffix("_a") || lower.hasSuffix("_b") ? String(lower.dropLast(2)) : lower
    }
    public static func protected(_ partition: DevicePartition, adb: Bool) -> Bool {
        // Matches Windows visual-flash policy: persist can be written; other
        // calibration partitions, plus ADB userdata / metadata, are protected.
        (partition.isBaseband && withoutSlot(partition.name) != "persist") || (adb && partition.isUserData)
    }
    public static func blockPath(_ value: String) throws -> String {
        guard value.range(of: "^/dev/block/[A-Za-z0-9_./-]+$", options: .regularExpression) != nil,
              value.utf8.count <= 1024, !value.split(separator: "/").contains(".."), !value.split(separator: "/").contains(".") else { throw InputError.invalid("块设备路径无效。") }
        return value
    }
    public static let listADB = """
    [ "$(id -u)" = 0 ] || exit 77
    root=
    for candidate in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do
      if [ -d "$candidate" ]; then root=$candidate; break; fi
    done
    [ -n "$root" ] || exit 72
    printf 'VIOLET_PARTITIONS_V1\\n'
    for item in "$root"/*; do
      [ -b "$item" ] || continue
      target=$(readlink -f "$item") || exit 73
      size=$(blockdev --getsize64 "$target" 2>/dev/null)
      if [ -z "$size" ]; then
        blocks=$(cat "/sys/class/block/${target##*/}/size") || exit 74
        size=$((blocks*512))
      fi
      printf '%s\\t%s\\t%s\\n' "${item##*/}" "$size" "$target"
    done
    """
    public static func parseADB(_ text: String) throws -> [DevicePartition] {
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw InputError.invalid("分区表响应过大。") }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.first == "VIOLET_PARTITIONS_V1", lines.count > 1, lines.count <= 16385 else { throw InputError.invalid("未读到有效 by-name 分区表，请检查 Root 权限与设备路径。") }
        var partitions: [DevicePartition] = [], names: Set<String> = []
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let size = UInt64(fields[1]), names.insert(fields[0]).inserted else { throw InputError.invalid("分区表响应无效或存在重复名称。") }
            partitions.append(try DevicePartition(name: fields[0], size: size, blockPath: fields[2]))
        }
        return partitions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func parseFastboot(_ text: String) throws -> [DevicePartition] {
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw InputError.invalid("Fastboot 响应过大。") }
        var sizes: [String: UInt64] = [:], types: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            for marker in ["partition-size:","partition-type:"] {
                guard let range = line.range(of: marker) else { continue }
                let fields = line[range.upperBound...].split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard fields.count == 2 else { throw InputError.invalid("Fastboot 分区字段不完整。") }
                let name = try Input.partition(fields[0])
                if marker == "partition-type:" { types[name] = fields[1]; continue }
                let value = fields[1].lowercased()
                guard let size = UInt64(value.hasPrefix("0x") ? String(value.dropFirst(2)) : value, radix: 16),
                      sizes[name] == nil || sizes[name] == size else { throw InputError.invalid("Fastboot 分区大小无效或冲突。") }
                sizes[name] = size
            }
        }
        guard !sizes.isEmpty, sizes.count <= 16384 else { throw InputError.invalid("设备未提供 partition-size 信息，请使用 ADB Root 读表或检查 Fastboot 模式。") }
        return try sizes.keys.sorted().map { try DevicePartition(name: $0, size: sizes[$0]!, type: types[$0] ?? "未知") }
    }
    public static func execOut(_ script: String) -> [String] { ["exec-out", "su -c " + Input.remoteQuote(script)] }
    public static func readRaw(_ partition: DevicePartition) throws -> [String] {
        guard let path = partition.blockPath else { throw InputError.invalid("ADB 回读缺少块设备路径。") }
        return execOut(try capacityGuard(partition) + " && dd if=\(Input.remoteQuote(path)) bs=1048576 2>/dev/null")
    }
    public static func write(_ partition: DevicePartition, remoteImage: String) throws -> [String] {
        guard let path = partition.blockPath else { throw InputError.invalid("ADB 写入缺少块设备路径。") }
        let image = try RemoteFiles.path(remoteImage, allowRoot: false)
        let script = try capacityGuard(partition) + " && [ -f \(Input.remoteQuote(image)) ] && [ \"$(stat -c %s \(Input.remoteQuote(image)))\" -le \(partition.size) ] && dd if=\(Input.remoteQuote(image)) of=\(Input.remoteQuote(path)) bs=1048576 conv=fsync && sync"
        return RootModuleCommands.shell(script)
    }
    public static func erase(_ partition: DevicePartition) throws -> [String] {
        guard let path = partition.blockPath else { throw InputError.invalid("ADB 擦除缺少块设备路径。") }
        // Bound the zero write by the exact declared capacity. Using an
        // unbounded /dev/zero dd would end with ENOSPC even after success.
        guard partition.size % 512 == 0 else { throw InputError.invalid("块设备容量未按 512 对齐。") }
        let blocks = partition.size / 1048576, tail = partition.size % 1048576 / 512
        var commands = [try capacityGuard(partition)]
        if blocks > 0 { commands.append("dd if=/dev/zero of=\(Input.remoteQuote(path)) bs=1048576 count=\(blocks) conv=fsync") }
        if tail > 0 { commands.append("dd if=/dev/zero of=\(Input.remoteQuote(path)) bs=512 seek=\(blocks * 2048) count=\(tail) conv=notrunc,fsync") }
        commands.append("sync")
        return RootModuleCommands.shell(commands.joined(separator: " && "))
    }
    private static func capacityGuard(_ partition: DevicePartition) throws -> String {
        guard let path = partition.blockPath else { throw InputError.invalid("缺少块设备路径。") }
        _ = try blockPath(path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let fallback = "/sys/class/block/" + name + "/size"
        return "[ \"$(id -u)\" = 0 ] && [ -b \(Input.remoteQuote(path)) ] && " +
            "{ found=0; for root in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do " +
            "if [ -d \"$root\" ]; then resolved=$(readlink -f \"$root/\(partition.name)\") || exit 73; [ \"$resolved\" = \(Input.remoteQuote(path)) ] || exit 73; found=1; break; fi; done; [ \"$found\" = 1 ]; } && " +
            "{ size=$(blockdev --getsize64 \(Input.remoteQuote(path)) 2>/dev/null); if [ -z \"$size\" ]; then blocks=$(cat \(Input.remoteQuote(fallback))) || exit 74; size=$((blocks*512)); fi; [ \"$size\" = \(partition.size) ]; }"
    }
}
