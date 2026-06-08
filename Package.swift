// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "questrade-mac-menu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "questrade-mac-menu", targets: ["questrade-mac-menu"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "questrade-mac-menu"
        ),
        .testTarget(
            name: "questrade-mac-menuTests",
            dependencies: [
                "questrade-mac-menu",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
