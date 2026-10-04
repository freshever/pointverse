// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StableDiffusionRuntime",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StableDiffusion", targets: ["StableDiffusion"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0"),
    ],
    targets: [
        .target(
            name: "StableDiffusion",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/StableDiffusion"
        ),
    ]
)
