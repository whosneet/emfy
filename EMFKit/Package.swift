// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "EMFKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EMFParse", targets: ["EMFParse"]),
        .library(name: "WMFParse", targets: ["WMFParse"]),
        .library(name: "EMFRender", targets: ["EMFRender"]),
        .executable(name: "emfy-dump", targets: ["emfy-dump"]),
    ],
    targets: [
        .target(name: "EMFParse"),
        .target(
            name: "WMFParse",
            dependencies: ["EMFParse"]
        ),
        .target(
            name: "EMFRender",
            dependencies: ["EMFParse", "WMFParse"]
        ),
        .executableTarget(
            name: "emfy-dump",
            dependencies: ["EMFParse", "WMFParse"]
        ),
        .testTarget(
            name: "EMFParseTests",
            dependencies: ["EMFParse"]
        ),
        .testTarget(
            name: "WMFParseTests",
            dependencies: ["WMFParse", "EMFParse"]
        ),
        .testTarget(
            name: "EMFRenderTests",
            dependencies: ["EMFRender", "EMFParse"],
            resources: [.copy("__Baselines__")]
        ),
    ]
)
