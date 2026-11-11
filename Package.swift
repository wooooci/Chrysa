// swift-tools-version: 6.0
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
        )
    ],
    swiftLanguageModes: [.v5]
)
