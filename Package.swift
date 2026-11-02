// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackerLite",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TrackerLite",
            path: "Sources/TrackerLite"
        )
    ],
    // Match RemindLite / MenuLite: Swift 6 compiler, Swift 5 language mode so the
    // AppKit bits stay clean and readable.
    swiftLanguageModes: [.v5]
)
