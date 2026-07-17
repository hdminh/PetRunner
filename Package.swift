// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PetRunner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PetRunnerCore", targets: ["PetRunnerCore"]),
        .executable(name: "PetRunner", targets: ["PetRunner"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.2-RELEASE"
        ),
    ],
    targets: [
        .target(name: "PetRunnerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PetRunner", dependencies: ["PetRunnerCore"]),
        .testTarget(
            name: "PetRunnerCoreTests",
            dependencies: [
                "PetRunnerCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
