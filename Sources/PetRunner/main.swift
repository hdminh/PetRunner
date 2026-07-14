import AppKit
import Darwin
import PetRunnerCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--agent-monitor-hook") {
    exit(AgentMonitorHookRunner.run(arguments: arguments))
}
if arguments.contains("--agent-monitor-cleanup") {
    do {
        try RustMonitor.removeAllHooks()
        exit(0)
    } catch {
        exit(1)
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
applicationDelegate.configureAgentMonitorOnLaunch = arguments.contains("--configure-agent-monitor")
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()
