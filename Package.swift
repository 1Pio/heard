// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "heard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "heard", targets: ["heard"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "heard",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .testTarget(name: "heardTests", dependencies: ["heard"])
    ]
)
