// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CapslockPlusMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CapslockPlusMac", targets: ["CapslockPlusMac"])
    ],
    targets: [
        .executableTarget(
            name: "CapslockPlusMac",
            path: "Sources/CapslockPlusMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
