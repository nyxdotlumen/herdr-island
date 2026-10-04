// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DynamicHerdr",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DynamicHerdr", targets: ["DynamicHerdr"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "IslandCore"),
        .executableTarget(
            name: "NativeInputChecks",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Tests/NativeInputChecks"
        ),
        .executableTarget(
            name: "DynamicHerdr",
            dependencies: ["IslandCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(
            name: "IslandCoreChecks",
            dependencies: ["IslandCore"],
            path: "Tests/IslandCoreTests"
        )
    ]
)
