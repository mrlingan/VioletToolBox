import Foundation

public struct OCDTImage: Sendable {
    public enum Platform: String, CaseIterable, Sendable { case qualcomm = "高通 · 128 KiB", mtk = "联发科 · 8 MiB" }
    public enum Variant: String, CaseIterable, Sendable { case standard, fill02, geyixue_fill, mixed_projid }
    public let sourceURL: URL
    public let size: UInt64
    public let projectIDs: [UInt64]
    public let variant: Variant
    public let osigVersion: UInt64?
    public let osigHasSignature: Bool
    private static let key = Array("geyixue".utf8)
    private static let legacyMTK: Set<UInt16> = [20001,20041,20131,20151,20613]
    private static let mixed: [UInt16: String] = [
        22801: "67c3979696c256762fb2968757567656979687575676569796875756765697968757567656979687575676569796875756765697",
        21644: "be1397963f125676eed2968757567656979687575676569796875756765697968757567656979687575676569796875756765697"
    ]
    private static func swap(_ byte: UInt8) -> UInt8 { byte << 4 | byte >> 4 }
    public static func open(_ url: URL) throws -> OCDTImage {
        let snapshot = try FileSnapshot(url)
        guard snapshot.size == 131072 || snapshot.size == 8388608 else { throw InputError.invalid("OCDT 应为 128 KiB（高通）或 8 MiB（MTK）。") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let header = try handle.readExactly(offset: 0, count: 0x1200, fileSize: snapshot.size)
        guard header.prefix(4) == Data("TDCO".utf8), try header.integer(at: 4, bytes: 2) == 1,
              try header.integer(at: 8, bytes: 4) == 0x10, try header.integer(at: 12, bytes: 4) == 52 else { throw InputError.invalid("OCDT TDCO 版本或配置范围无效。") }
        let plain = Data(header[16..<68].enumerated().map { swap($0.element) ^ key[$0.offset % key.count] })
        let ids = try [0,4,8].map { try plain.integer(at: $0, bytes: 2) }
        let geyixueFill = (22..<52).allSatisfy { plain[$0] == key[$0 % key.count] }
        let variant: Variant = Set(ids).count > 1 ? .mixed_projid : plain[2] == 2 ? .fill02 : geyixueFill ? .geyixue_fill : .standard
        let hasOSIG = header.subdata(in: 0x1000..<0x1004) == Data("OSIG".utf8)
        // Presence of bytes is not cryptographic signature verification.
        let signature = hasOSIG && header[0x1100..<0x1200].contains(where: { $0 != 0 })
        try snapshot.validate()
        return OCDTImage(sourceURL: url, size: snapshot.size, projectIDs: ids, variant: variant,
                         osigVersion: hasOSIG ? try header.integer(at: 0x1004, bytes: 4) : nil, osigHasSignature: signature)
    }
    public static func generate(project: UInt16, platform: Platform, variant: Variant, to target: URL, control: WorkControl = WorkControl()) throws -> URL {
        try control.check()
        guard project > 0 else { throw InputError.invalid("项目号应为 1–65535。") }
        var plain = Data(count: 52)
        for offset in [0,4,8] { plain.replaceSubrange(offset..<offset + 2, with: [UInt8(truncatingIfNeeded: project), UInt8(project >> 8)]) }
        if variant == .fill02 { for offset in [2,6,10] { plain[offset] = 2 } }
        if variant == .geyixue_fill { for i in 22..<52 { plain[i] = key[i % key.count] } }
        var config = Data(plain.enumerated().map { swap($0.element ^ key[$0.offset % key.count]) })
        if variant == .mixed_projid {
            guard let hex = mixed[project] else { throw InputError.invalid("mixed_projid 仅有上游提供的项目号 22801 / 21644 配置。") }
            config = Data(stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset); return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            })
        }
        var bytes = Data(count: platform == .qualcomm ? 131072 : 8388608)
        bytes.replaceSubrange(0..<16, with: Data([0x54,0x44,0x43,0x4f,1,0,0,0,16,0,0,0,52,0,0,0]))
        bytes.replaceSubrange(16..<68, with: config)
        if platform == .qualcomm || legacyMTK.contains(project) {
            var osig = Data(count: 512)
            osig.replaceSubrange(0..<4, with: Data("OSIG".utf8)); osig[0x10] = 0x30
            if platform == .qualcomm {
                osig.replaceSubrange(0x50..<0x60, with: bytes.prefix(16))
                bytes.replaceSubrange(0x2000..<0x2200, with: osig)
            }
            bytes.replaceSubrange(0x1000..<0x1200, with: osig)
        }
        let output = try AtomicOutput(target)
        try output.handle.write(contentsOf: bytes); try control.check()
        return try output.commit()
    }
}
