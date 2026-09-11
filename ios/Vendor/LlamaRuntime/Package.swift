// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LlamaRuntime",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10809/llama-b10809-xcframework.zip",
            checksum: "d6813b3b6c73728a19f0bc0d1d7cea04ccdb07f9583c1d930c0b38af2377606d"
        )
    ]
)
