import AppKit
import OSLog
import PetRunnerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var configureAgentMonitorOnLaunch = false
    private let logger = Logger(subsystem: "vn.hodinhminh.petrunner", category: "app")
    private let preferences = PetRunnerPreferences()
    private let overlay = OverlayPanelController()
    private let monitorBridge = AgentMonitorBridge()
    private let monitorStore = RustAgentSessionStore()
    private var terminalSessionExpiry: [AgentSessionKey: DispatchWorkItem] = [:]
    private var titleResolutionTasks: [AgentSessionKey: TitleResolutionTask] = [:]
    private let sessionBubble = SessionBubblePanelController()
    private var monitorSetup: MonitorSetupWindowController?
    private var statusMenu: StatusMenuController?
    private var petsDirectory: URL!
    private var pets: [PetDescriptor] = []
    private var failures: [PetFailure] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        petsDirectory = resolvePetsDirectory()

        let menu = StatusMenuController()
        menu.onSelectPet = { [weak self] id in self?.selectPet(id: id) }
        menu.onSelectSize = { [weak self] width in self?.selectSize(width) }
        menu.onReload = { [weak self] in self?.reloadPets() }
        menu.onToggleMonitor = { [weak self] in self?.toggleMonitor() }
        menu.onRepairMonitor = { [weak self] in self?.repairMonitorHooks() }
        menu.onQuit = { NSApp.terminate(nil) }
        statusMenu = menu

        overlay.onPositionChanged = { [weak self] origin in self?.preferences.origin = origin }
        overlay.onSizeChanged = { [weak self] width in
            self?.preferences.petWidth = width
            self?.refreshMenu()
        }
        sessionBubble.onSelectPrevious = { [weak self] in self?.selectPreviousSession() }
        sessionBubble.onSelectNext = { [weak self] in self?.selectNextSession() }
        sessionBubble.onCollapse = { [weak self] in self?.setMonitorBubbleCollapsed(true) }
        sessionBubble.onExpand = { [weak self] in self?.setMonitorBubbleCollapsed(false) }
        overlay.onFrameChanged = { [weak self] _ in self?.refreshMonitorPresentation() }
        reloadPets()
        if configureAgentMonitorOnLaunch {
            DispatchQueue.main.async { [weak self] in self?.presentMonitorSetup(exitAfterDismissal: true) }
        }
        if preferences.monitorEnabled {
            do {
                try startMonitorBridge()
            } catch {
                logger.error("Failed to start monitor bridge: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            AgentMonitorBridge.removeDescriptor()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelTerminalExpiry()
        cancelTitleResolution()
        overlay.stop()
        monitorBridge.stop()
    }

    private func reloadPets() {
        let result = PetLibrary().scan(at: petsDirectory)
        pets = result.valid
        failures = result.invalid

        guard !pets.isEmpty else {
            overlay.hide()
            preferences.selectedPetID = nil
            refreshMenu()
            logger.error("No valid pets found in \(self.petsDirectory.path, privacy: .public)")
            return
        }

        let preferred = pets.first { $0.id == preferences.selectedPetID }
        let ordered = preferred.map { preferredPet in
            [preferredPet] + pets.filter { $0.id != preferredPet.id }
        } ?? pets
        var loadedPet: PetDescriptor?
        for pet in ordered {
            do {
                try overlay.show(pet: pet, width: preferences.petWidth, savedOrigin: preferences.origin)
                loadedPet = pet
                break
            } catch {
                failures.append(PetFailure(id: pet.id, message: error.localizedDescription))
                logger.error("Failed to render pet \(pet.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if let loadedPet {
            preferences.selectedPetID = loadedPet.id
        } else {
            overlay.hide()
            preferences.selectedPetID = nil
        }
        refreshMenu()
    }

    private func selectPet(id: String) {
        guard let pet = pets.first(where: { $0.id == id }) else { return }
        do {
            try overlay.show(pet: pet, width: preferences.petWidth, savedOrigin: preferences.origin)
            preferences.selectedPetID = pet.id
        } catch {
            failures.removeAll { $0.id == pet.id }
            failures.append(PetFailure(id: pet.id, message: error.localizedDescription))
            logger.error("Failed to select pet \(pet.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        refreshMenu()
    }

    private func selectSize(_ width: CGFloat) {
        preferences.petWidth = width
        overlay.setWidth(preferences.petWidth)
        refreshMenu()
    }

    private func refreshMenu() {
        statusMenu?.update(
            pets: pets,
            failures: failures,
            selectedID: preferences.selectedPetID,
            width: preferences.petWidth,
            monitorEnabled: preferences.monitorEnabled
        )
    }

    private func toggleMonitor() {
        if preferences.monitorEnabled {
            do {
                try RustMonitor.removeAllHooks()
                preferences.monitorEnabled = false
                preferences.monitorProviders = []
                cancelTerminalExpiry()
                cancelTitleResolution()
                monitorStore.removeAll()
                monitorBridge.stop()
                sessionBubble.hide()
                overlay.setMonitorAnimation(nil)
            } catch {
                logger.error("Failed to remove monitor hooks: \(error.localizedDescription, privacy: .public)")
                showMonitorError("PetRunner could not remove all of its monitor hooks. Your monitoring setup is still enabled; repair the provider config and try again.")
            }
            refreshMenu()
            return
        }
        presentMonitorSetup(exitAfterDismissal: false)
    }

    private func presentMonitorSetup(exitAfterDismissal: Bool) {
        let detections = RustMonitor.detect(existingPaths: Set([".claude", ".codex", ".cursor"].filter {
            FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path)
        }))
        let setup = MonitorSetupWindowController()
        monitorSetup = setup
        setup.onDismiss = { [weak self] in
            self?.monitorSetup = nil
            if exitAfterDismissal { NSApp.terminate(nil) }
        }
        setup.present(detections: detections) { [weak self] providers in
            guard let self, !providers.isEmpty, let executable = Bundle.main.executableURL?.path else { return }
            do {
                try self.startMonitorBridge()
                do {
                    try RustMonitor.installHooks(providers, executablePath: executable)
                } catch {
                    self.monitorBridge.stop()
                    throw error
                }
                self.preferences.monitorProviders = providers
                self.preferences.monitorEnabled = true
                self.refreshMenu()
            } catch {
                self.logger.error("Failed to install monitor hooks: \(error.localizedDescription, privacy: .public)")
                self.showMonitorError("PetRunner did not enable monitoring. \(error.localizedDescription)")
            }
        }
    }

    private func repairMonitorHooks() {
        guard preferences.monitorEnabled,
              !preferences.monitorProviders.isEmpty,
              let executable = Bundle.main.executableURL?.path
        else { return }
        do {
            try startMonitorBridge()
            try RustMonitor.installHooks(preferences.monitorProviders, executablePath: executable)
        } catch {
            logger.error("Failed to repair monitor hooks: \(error.localizedDescription, privacy: .public)")
            showMonitorError("PetRunner could not repair its monitor hooks. \(error.localizedDescription)")
        }
    }

    private func startMonitorBridge() throws {
        monitorBridge.onEvent = { [weak self] event in
            guard let self else { return }
            self.terminalSessionExpiry.removeValue(forKey: event.key)?.cancel()
            self.monitorStore.upsert(event)
            self.cancelTitleResolutionForUnretainedSessions()
            if event.provider == .cursor {
                self.resolveCursorTitle(for: event.key)
            }
            if event.status == .finished || event.status == .failed {
                self.expireTerminalSession(event.key)
            }
            self.refreshMonitorPresentation()
        }
        try monitorBridge.start()
    }

    private func selectPreviousSession() {
        monitorStore.selectPrevious()
        refreshMonitorPresentation()
    }

    private func selectNextSession() {
        monitorStore.selectNext()
        refreshMonitorPresentation()
    }

    private func setMonitorBubbleCollapsed(_ isCollapsed: Bool) {
        preferences.monitorBubbleCollapsed = isCollapsed
        refreshMonitorPresentation()
    }

    private func refreshMonitorPresentation() {
        guard let selected = monitorStore.selected else { sessionBubble.hide(); overlay.setMonitorAnimation(nil); return }
        overlay.setMonitorAnimation(selected.animation)
        sessionBubble.update(
            entries: monitorStore.entries,
            selectedIndex: monitorStore.selectedIndex,
            petFrame: overlay.frame,
            isCollapsed: preferences.monitorBubbleCollapsed
        )
    }

    private func expireTerminalSession(_ key: AgentSessionKey) {
        let expiry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.terminalSessionExpiry.removeValue(forKey: key)
            self.cancelTitleResolution(for: key)
            if self.monitorStore.remove(key) {
                self.refreshMonitorPresentation()
            }
        }
        terminalSessionExpiry[key] = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5), execute: expiry)
    }

    private func cancelTerminalExpiry() {
        terminalSessionExpiry.values.forEach { $0.cancel() }
        terminalSessionExpiry.removeAll()
    }

    private func resolveCursorTitle(for key: AgentSessionKey) {
        guard titleResolutionTasks[key] == nil,
              monitorStore.entries.first(where: { $0.key == key })?.displayName?.source != .nativeProvider
        else { return }
        let identifier = UUID()
        let task = Task { [weak self] in
            defer { self?.completeTitleResolution(for: key, identifier: identifier) }
            // Delays are measured from the hook event: immediately, then 0.5s and 2s later.
            for delay in [UInt64(0), 500_000_000, 1_500_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }
                let displayName = await Task.detached(priority: .utility) {
                    RustMonitor.cursorTitle(
                        database: FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/conversation-search.db"),
                        conversationID: key.sessionID
                    )
                }.value
                guard !Task.isCancelled else { return }
                if let displayName {
                    self?.applyResolvedCursorTitle(displayName, for: key)
                    return
                }
            }
        }
        titleResolutionTasks[key] = TitleResolutionTask(identifier: identifier, task: task)
    }

    private func applyResolvedCursorTitle(_ displayName: AgentSessionDisplayName, for key: AgentSessionKey) {
        guard monitorStore.setDisplayName(displayName, for: key) else { return }
        cancelTitleResolution(for: key)
        refreshMonitorPresentation()
    }

    private func cancelTitleResolution(for key: AgentSessionKey? = nil) {
        if let key {
            titleResolutionTasks.removeValue(forKey: key)?.task.cancel()
            return
        }
        titleResolutionTasks.values.forEach { $0.task.cancel() }
        titleResolutionTasks = [:]
    }

    private func completeTitleResolution(for key: AgentSessionKey, identifier: UUID) {
        guard titleResolutionTasks[key]?.identifier == identifier else { return }
        titleResolutionTasks.removeValue(forKey: key)
    }

    private func cancelTitleResolutionForUnretainedSessions() {
        let retained = Set(monitorStore.entries.map(\.key))
        for key in titleResolutionTasks.keys where !retained.contains(key) {
            cancelTitleResolution(for: key)
        }
    }

    private func showMonitorError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Agent Monitor"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func resolvePetsDirectory() -> URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--pets-dir"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath, isDirectory: true)
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            return URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("pets", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }
}

private struct TitleResolutionTask {
    let identifier: UUID
    let task: Task<Void, Never>
}
