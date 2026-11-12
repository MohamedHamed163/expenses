// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Expenses",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ExpensesKit", targets: ["ExpensesKit"]),
        .executable(name: "ExpensesApp", targets: ["ExpensesApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "ExpensesKit",
            dependencies: [.product(name: "PostgresNIO", package: "postgres-nio")],
            path: "Sources/ExpensesKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ExpensesApp",
            dependencies: ["ExpensesKit", .product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/ExpensesApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ExpensesKitTests",
            dependencies: ["ExpensesKit"],
            path: "Tests/ExpensesKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
