// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReaderCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
    ],
    dependencies: [
        // EPUB and zipped FB2 are zip archives; iOS has no public unzip API.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        // DjVuLibre 3.5.28 (GPL-2.0), vendored unmodified apart from a hand-trimmed config.h.
        .target(
            name: "CDjVuLibre",
            exclude: ["COPYING"],
            cxxSettings: [
                .define("HAVE_CONFIG_H"),
                .define("DIR_DATADIR", to: "\"/usr/share\""),
                .headerSearchPath("."),
                .unsafeFlags(["-w"]),
            ]
        ),
        // CHMLib 0.40 (LGPL-2.1), vendored unmodified.
        .target(
            name: "CCHMLib",
            exclude: ["COPYING"],
            cSettings: [
                // pread is 64-bit on Apple platforms (no pread64), so CHM_USE_IO64 is not needed.
                .define("CHM_MT"), .define("CHM_USE_PREAD"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "ReaderCore",
            dependencies: ["CDjVuLibre", "CCHMLib", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: ["ReaderCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx14
)
