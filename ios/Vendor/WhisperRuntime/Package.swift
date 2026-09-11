// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperRuntime",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "whisper", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        )
    ]
)
