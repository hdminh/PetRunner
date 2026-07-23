// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PetRunner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PetRunner", targets: ["PetRunner"]),
    ],
    targets: [
        .target(
            name: "PetRunnerCore",
            exclude: ["AgentMonitor 2.swift", "AgentMonitorBridgeContract 2.swift", "Animation 2.swift", "PetPackage 2.swift", "Physics 2.swift", "PixelGlyphs 2.swift", "ProviderDetection 2.swift", "ProviderHookConfiguration 2.swift", "ProviderHookInstaller 2.swift", "SessionBubbleLayout 2.swift"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "PetRunner", dependencies: ["PetRunnerCore"], exclude: ["AgentMonitorBridge 2.swift", "PixelTextView 2.swift"]),
    ]
)
