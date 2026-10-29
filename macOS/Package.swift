// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VioletToolBox",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "VioletToolBox", targets: ["VioletMac"])],
    targets: [
        .target(name: "CZstdDecoder", exclude: ["README.md", "UPSTREAM.json", "vendor/LICENSE", "vendor/COPYING", "vendor/common/pool.c", "vendor/common/threading.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("vendor"), .define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("ZSTD_DISABLE_ASM", to: "1"), .define("XXH_NAMESPACE", to: "VioletZSTD_")]),
        .target(name: "VioletNative", dependencies: ["CZstdDecoder"], linkerSettings: [.linkedLibrary("bz2"), .linkedLibrary("lzma"), .linkedLibrary("archive"), .linkedLibrary("z")]),
        .target(name: "VioletCore", dependencies: ["VioletNative"]),
        .executableTarget(name: "VioletMac", dependencies: ["VioletCore"]),
        .testTarget(name: "VioletCoreTests", dependencies: ["VioletCore"], exclude: ["Fixtures"]),
        .testTarget(name: "VioletMacTests", dependencies: ["VioletMac", "VioletCore"])
    ]
)
