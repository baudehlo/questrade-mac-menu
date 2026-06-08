// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "questrade-mac-menu",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "questrade-mac-menu", targets: ["questrade-mac-menu"])
    ],
    targets: [
        .executableTarget(
            name: "questrade-mac-menu"
        ),
        .testTarget(
            name: "questrade-mac-menuTests",
            dependencies: ["questrade-mac-menu"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
