// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PetRunner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PetRunner", targets: ["PetRunner"]),
    ],
    targets: [
        .target(name: "PetRunnerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PetRunner", dependencies: ["PetRunnerCore"]),
    ]
)
