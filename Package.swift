// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chrysa",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Chrysa", targets: ["Chrysa"])
    ],
    targets: [
        .executableTarget(
            name: "Chrysa",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "ChrysaTests",
            dependencies: ["Chrysa"],
            path: "Tests/ChrysaTests"
        )
    ]
)
