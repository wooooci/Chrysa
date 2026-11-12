// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chrysa",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Chrysa", targets: ["Chrysa"])],
    targets: [
        .target(name: "ChrysaCore", path: "Sources/Core"),
        .target(name: "ChrysaApplication", dependencies: ["ChrysaCore"], path: "Sources/Application"),
        .target(
            name: "ChrysaAdapters",
            dependencies: ["ChrysaCore", "ChrysaApplication"],
            path: "Sources/Adapters",
            linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("CryptoKit")]
        ),
        .target(
            name: "ChrysaPresentation",
            dependencies: ["ChrysaCore", "ChrysaApplication"],
            path: "Sources/Presentation",
            linkerSettings: [
                .linkedFramework("SwiftUI"), .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"), .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "Chrysa",
            dependencies: ["ChrysaCore", "ChrysaApplication", "ChrysaAdapters", "ChrysaPresentation"],
            path: "Sources/App"
        ),
        .testTarget(name: "ChrysaCoreTests", dependencies: ["ChrysaCore"]),
        .testTarget(name: "ChrysaApplicationTests", dependencies: ["ChrysaCore", "ChrysaApplication"]),
        .testTarget(
            name: "ChrysaTests",
            dependencies: ["Chrysa", "ChrysaCore", "ChrysaApplication", "ChrysaAdapters", "ChrysaPresentation"]
        )
    ],
    swiftLanguageModes: [.v5]
)
