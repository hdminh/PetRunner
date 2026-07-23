import AppKit
import Darwin
import PetRunnerCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--agent-monitor-hook") {
    exit(AgentMonitorHookRunner.run(arguments: arguments))
}
if arguments.contains("--agent-monitor-cleanup") {
    do {
        try ProviderHookInstaller().removeAll()
        exit(0)
    } catch {
        exit(1)
    }
}

let launchesInBackground = arguments.contains("--background")
switch SingleInstanceCoordinator.acquire() {
case .secondary:
    if !launchesInBackground { SingleInstanceCoordinator.requestDashboard() }
    exit(0)
case let .primary(singleInstance):
    let application = NSApplication.shared
    let applicationDelegate = AppDelegate(launchesInBackground: launchesInBackground)
    application.delegate = applicationDelegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime((applicationDelegate, singleInstance)) {
        application.run()
    }
}
