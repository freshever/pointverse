// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointVerseKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PointVerseKit", targets: ["PointVerseKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0")
    ],
    targets: [
        .target(
            name: "PointVerseKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "PointVerseKitTests", dependencies: ["PointVerseKit"])
    ]
)
