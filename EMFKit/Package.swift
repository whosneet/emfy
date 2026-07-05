// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "EMFKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EMFParse", targets: ["EMFParse"]),
        .library(name: "EMFRender", targets: ["EMFRender"]),
        .executable(name: "emfy-dump", targets: ["emfy-dump"]),
    ],
    targets: [
        .target(name: "EMFParse"),
        .target(
            name: "EMFRender",
            dependencies: ["EMFParse"]
        ),
        .executableTarget(
            name: "emfy-dump",
            dependencies: ["EMFParse"]
        ),
        .testTarget(
            name: "EMFParseTests",
            dependencies: ["EMFParse"]
        ),
        .testTarget(
            name: "EMFRenderTests",
            dependencies: ["EMFRender", "EMFParse"],
            resources: [.copy("__Baselines__")]
        ),
    ]
)
