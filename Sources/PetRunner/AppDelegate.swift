import AppKit
import OSLog
import PetRunnerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchesInBackground: Bool
    private let logger = Logger(subsystem: "vn.hodinhminh.petrunner", category: "app")
    private let preferences = PetRunnerPreferences()
    private let overlay = OverlayPanelController()
    private let monitorBridge = AgentMonitorBridge()
    private var monitorStore = AgentSessionStore()
    private var terminalSessionExpiry: [AgentSessionKey: DispatchWorkItem] = [:]
    private var historyStore: AgentSessionHistoryStore?
    private var historyError: String?
    private let sessionBubble = SessionBubblePanelController()
    private var monitorSetup: MonitorSetupWindowController?
    private var dashboardAPI: DashboardAPIController?
    private var dashboardServer: LocalDashboardServer?
    private var statusMenu: StatusMenuController?
    private var quickActions: QuickActionsMenuController?
    private var usageCoordinator: UsageCoordinator?
    private var usageSnapshot: UsageSnapshot?
    private let budgetNotifications = BudgetNotificationController()
    private var usageRefreshTimer: Timer?
    private var petsDirectory: URL!
    private var petsDirectoryLockedByCLI = false
    private var petsDirectorySource = "default"
    private var pets: [PetDescriptor] = []
    private var failures: [PetFailure] = []

    init(launchesInBackground: Bool = false) {
        self.launchesInBackground = launchesInBackground
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        petsDirectory = resolvePetsDirectory()
        installBundledDefaultPetIfNeeded()
        preferences.migrateLegacyMonitorProviderIfNeeded()
        configureHistoryStore()

        let menu = StatusMenuController()
        menu.onSelectPet = { [weak self] id in self?.selectPet(id: id) }
        menu.onSelectSize = { [weak self] width in self?.selectSize(width) }
        menu.onReload = { [weak self] in self?.reloadPets() }
        menu.onOpenDashboard = { [weak self] in self?.openDashboard() }
        menu.onToggleMonitor = { [weak self] in self?.toggleMonitor() }
        menu.onConfigureMonitor = { [weak self] in self?.presentMonitorSetup() }
        menu.onRepairMonitor = { [weak self] in self?.repairMonitorHooks() }
        menu.onToggleAutonomy = { [weak self] in self?.toggleAutonomy() }
        menu.onQuit = { NSApp.terminate(nil) }
        statusMenu = menu
        menu.setVisible(preferences.showsStatusItem)

        let quickActions = QuickActionsMenuController { [weak self] in
            guard let self else { return nil }
            return .init(
                pets: self.pets,
                selectedPetID: self.preferences.selectedPetID,
                monitorEnabled: self.preferences.monitorEnabled,
                autonomyEnabled: self.preferences.autonomyEnabled,
                todayUsage: self.usageSnapshot?.todayText ?? "No data",
                monthUsage: self.usageSnapshot?.monthText ?? "No data"
            )
        }
        quickActions.onOpenDashboard = { [weak self] in self?.openDashboard() }
        quickActions.onRefreshUsage = { [weak self] in self?.refreshUsage() }
        quickActions.onSelectPet = { [weak self] in self?.selectPet(id: $0) }
        quickActions.onImportPet = { [weak self] in self?.openDashboard() }
        quickActions.onToggleAutonomy = { [weak self] in self?.toggleAutonomy() }
        quickActions.onToggleMonitor = { [weak self] in self?.toggleMonitor() }
        quickActions.onQuit = { NSApp.terminate(nil) }
        self.quickActions = quickActions
        overlay.contextMenuProvider = { [weak quickActions] in quickActions?.makeMenu() }

        overlay.onPositionChanged = { [weak self] origin in self?.preferences.origin = origin }
        overlay.onSizeChanged = { [weak self] width in
            self?.preferences.petWidth = width
            self?.refreshMenu()
        }
        sessionBubble.onSelectPrevious = { [weak self] in self?.selectPreviousSession() }
        sessionBubble.onSelectNext = { [weak self] in self?.selectNextSession() }
        sessionBubble.onCollapse = { [weak self] in self?.setMonitorBubbleCollapsed(true) }
        sessionBubble.onExpand = { [weak self] in self?.setMonitorBubbleCollapsed(false) }
        sessionBubble.onReset = { [weak self] in self?.resetMonitorSessions() }
        overlay.onFrameChanged = { [weak self] _ in self?.refreshMonitorPresentation() }
        overlay.setAutonomyEnabled(preferences.autonomyEnabled)
        overlay.setAutonomyConfiguration(preferences.autonomyConfiguration)
        reloadPets()
        configureUsageCoordinator()
        if preferences.monitorEnabled, preferences.monitorProvider != nil {
            do {
                try startMonitorBridge()
                restoreRecoveredMonitorSessions()
            } catch {
                logger.error("Failed to start monitor bridge: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            AgentMonitorBridge.removeDescriptor()
            AgentMonitorBridge.removeRecoveryJournal()
        }
        configureDashboardServer()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showDashboardFromSecondaryLaunch),
            name: SingleInstanceCoordinator.showDashboardNotification,
            object: nil
        )
        if !launchesInBackground { openDashboard() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelTerminalExpiry()
        usageRefreshTimer?.invalidate()
        overlay.stop()
        monitorBridge.stop()
        dashboardServer?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func showDashboardFromSecondaryLaunch() { openDashboard() }

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

        let ordered = PetSelectionOrdering.orderedCandidates(
            from: pets,
            selectedID: preferences.selectedPetID
        )
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
            monitorEnabled: preferences.monitorEnabled,
            autonomyEnabled: preferences.autonomyEnabled
        )
        refreshStatusItemSpend()
    }

    /// Same rule as the dashboard topbar chip: Monitor-selected provider’s today cost,
    /// or icon-only when Monitor is off / no provider is selected.
    private func refreshStatusItemSpend() {
        statusMenu?.updateMonitorSpend(monitorSpendText())
    }

    private func monitorSpendText() -> String? {
        guard preferences.monitorEnabled,
              let provider = preferences.monitorProvider,
              let usageProvider = UsageProvider(rawValue: provider.rawValue)
        else { return nil }
        let today = UsageAggregate(
            records: usageSnapshot?.today.records.filter { $0.provider == usageProvider } ?? []
        )
        return String(format: "$%.2f", today.knownCostUSD)
    }

    private func toggleMonitor() {
        if preferences.monitorEnabled {
            do {
                try disableMonitor()
            } catch {
                logger.error("Failed to remove monitor hooks: \(error.localizedDescription, privacy: .public)")
                showMonitorError("PetRunner could not remove all of its monitor hooks. Your monitoring setup is still enabled; repair the provider config and try again.")
            }
            return
        }
        presentMonitorSetup()
    }

    private func presentMonitorSetup() {
        let detections = monitorProviderDetections()
        let setup = MonitorSetupWindowController()
        monitorSetup = setup
        setup.onDismiss = { [weak self] in self?.monitorSetup = nil }
        setup.present(
            detections: detections,
            selectedProvider: preferences.monitorProvider
        ) { [weak self] provider in
            guard let self else { return }
            do {
                try self.enableMonitor(provider: provider)
            } catch {
                self.logger.error("Failed to install monitor hooks: \(error.localizedDescription, privacy: .public)")
                self.showMonitorError("PetRunner did not enable monitoring. \(error.localizedDescription)")
            }
        }
    }

    private func enableMonitor(provider: AgentProvider) throws {
        guard let executable = Bundle.main.executableURL?.path else {
            throw ProviderHookInstallError(
                provider: provider,
                path: ProviderHookConfiguration(provider: provider).configURL().path,
                reason: "PetRunner executable path is unavailable"
            )
        }
        try startMonitorBridge()
        do {
            try ProviderHookInstaller().replace(with: provider, executablePath: executable)
        } catch {
            monitorBridge.stop()
            throw error
        }
        preferences.monitorProvider = provider
        preferences.monitorEnabled = true
        refreshMenu()
    }

    private func disableMonitor() throws {
        try ProviderHookInstaller().removeAll()
        preferences.monitorEnabled = false
        preferences.monitorProvider = nil
        clearMonitorSessions()
        monitorBridge.stop()
        refreshMenu()
    }

    /// Clears stuck or finished monitor presentation without disabling hooks.
    private func resetMonitorSessions() {
        clearMonitorSessions()
    }

    /// Shared teardown for disable and manual reset: drop active sessions,
    /// cancel terminal expiry, clear recovery journal, hide the bubble, and
    /// return the pet to its non-monitor animation.
    private func clearMonitorSessions() {
        cancelTerminalExpiry()
        monitorStore.removeAll()
        AgentMonitorBridge.removeRecoveryJournal()
        sessionBubble.hide()
        overlay.setMonitorAnimation(nil)
    }

    private func monitorProviderDetections() -> [ProviderDetection] {
        ProviderDetector.detect(existingPaths: Set([".claude", ".codex", ".cursor"].filter {
            FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path)
        }))
    }

    private func repairMonitorHooks() {
        guard preferences.monitorEnabled,
              let provider = preferences.monitorProvider
        else { return }
        do {
            try enableMonitor(provider: provider)
        } catch {
            logger.error("Failed to repair monitor hooks: \(error.localizedDescription, privacy: .public)")
            showMonitorError("PetRunner could not repair its monitor hooks. \(error.localizedDescription)")
        }
    }

    private func startMonitorBridge() throws {
        monitorBridge.onEvent = { [weak self] event in
            guard let self, MonitorEventFilter(selectedProvider: self.preferences.monitorProvider).accepts(event) else { return }
            guard self.monitorStore.accepts(event) else {
                try? AgentMonitorRecoveryJournal(url: AgentMonitorBridge.recoveryJournalURL).remove(event.key)
                return
            }
            _ = self.recordHistory(event)
            self.terminalSessionExpiry.removeValue(forKey: event.key)?.cancel()
            let changed = self.monitorStore.upsert(event)
            if event.status == .finished || event.status == .failed {
                self.expireTerminalSession(event.key)
            }
            if changed { self.refreshMonitorPresentation() }
        }
        try monitorBridge.start()
    }

    private func restoreRecoveredMonitorSessions() {
        let journal = AgentMonitorRecoveryJournal(url: AgentMonitorBridge.recoveryJournalURL)
        guard let events = try? journal.recoveredEvents(), !events.isEmpty else { return }
        for event in events where event.provider == preferences.monitorProvider {
            guard monitorStore.accepts(event) else {
                try? journal.remove(event.key)
                continue
            }
            _ = monitorStore.upsert(event)
        }
        _ = monitorStore.select(at: 0)
        refreshMonitorPresentation()
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

    private func toggleAutonomy() {
        preferences.autonomyEnabled.toggle()
        overlay.setAutonomyEnabled(preferences.autonomyEnabled)
        refreshMenu()
    }

    private func setAutonomyConfiguration(_ configuration: AutonomyConfiguration) {
        preferences.autonomyConfiguration = configuration
        overlay.setAutonomyConfiguration(configuration)
        refreshMenu()
    }

    private func resetPetPosition() {
        overlay.resetPositionToDefault()
    }

    private func removePet(id: String) throws {
        try PetRemovalService().remove(id: id, from: petsDirectory)
        if preferences.selectedPetID == id {
            preferences.selectedPetID = nil
        }
        reloadPets()
    }

    private func choosePetsDirectory() {
        guard !petsDirectoryLockedByCLI else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder PetRunner should scan for pet packages."
        panel.directoryURL = petsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyPetsDirectory(url, source: "preference")
    }

    private func setPetsDirectory(_ path: String) throws {
        guard !petsDirectoryLockedByCLI else {
            throw PetsDirectoryError.lockedByCLI
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PetsDirectoryError.invalidPath }
        let url = URL(
            fileURLWithPath: (trimmed as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        applyPetsDirectory(url, source: "preference")
    }

    private func revealPetsDirectory() {
        NSWorkspace.shared.open(petsDirectory)
    }

    private func applyPetsDirectory(_ url: URL, source: String) {
        preferences.petsDirectory = url
        petsDirectory = url
        petsDirectorySource = source
        installBundledDefaultPetIfNeeded()
        reloadPets()
    }

    private func installBundledDefaultPetIfNeeded() {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent(DefaultPet.bundleRelativePath, isDirectory: true)
        else { return }
        do {
            _ = try DefaultPetInstaller().installIfMissing(bundledPackage: bundled, into: petsDirectory)
        } catch {
            logger.error("Failed to install bundled default pet: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureHistoryStore() {
        do {
            historyStore = try AgentSessionHistoryStore(
                url: AgentMonitorBridge.runtimeDirectoryURL.appendingPathComponent("session-history.sqlite", isDirectory: false)
            )
            historyError = nil
        } catch {
            historyStore = nil
            historyError = error.localizedDescription
            logger.error("Failed to open session history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordHistory(_ event: NormalizedAgentEvent) -> Bool {
        guard let historyStore else { return false }
        do {
            return try historyStore.record(event)
        } catch {
            historyError = error.localizedDescription
            logger.error("Failed to record session history: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func openDashboard() {
        if dashboardServer == nil { configureDashboardServer() }
        guard let url = dashboardServer?.baseURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func configureDashboardServer() {
        guard dashboardServer == nil else { return }
        let api = DashboardAPIController(
            historyStore: { [weak self] in self?.historyStore },
            historyError: { [weak self] in self?.historyError },
            usageState: { [weak self] in self?.usageSnapshot },
            petState: { [weak self] in
                guard let self else {
                    return DashboardPetState(
                        pets: [], failures: [], selectedPetID: nil, width: 112,
                        autonomyEnabled: true, autonomyConfiguration: .default,
                        petsDirectory: "", petsDirectorySource: "default", petsDirectoryEditable: false
                    )
                }
                return DashboardPetState(
                    pets: self.pets,
                    failures: self.failures,
                    selectedPetID: self.preferences.selectedPetID,
                    width: self.preferences.petWidth,
                    autonomyEnabled: self.preferences.autonomyEnabled,
                    autonomyConfiguration: self.preferences.autonomyConfiguration,
                    petsDirectory: self.petsDirectory.path,
                    petsDirectorySource: self.petsDirectorySource,
                    petsDirectoryEditable: !self.petsDirectoryLockedByCLI
                )
            },
            showsStatusItem: { [weak self] in self?.preferences.showsStatusItem ?? true },
            budgetConfigurations: { [weak self] in self?.preferences.budgetConfigurations ?? [:] },
            isProviderEnabled: { [weak self] provider in self?.preferences.isProviderEnabled(provider) ?? true },
            onSelectPet: { [weak self] in self?.selectPet(id: $0) },
            onSetWidth: { [weak self] in self?.selectSize($0) },
            onResetPosition: { [weak self] in self?.resetPetPosition() },
            onRemovePet: { [weak self] id in
                guard let self else { throw PetRemovalError.notFound(id) }
                try self.removePet(id: id)
            },
            onSetAutonomy: { [weak self] enabled, configuration in
                guard let self else { return }
                self.preferences.autonomyEnabled = enabled
                self.overlay.setAutonomyEnabled(enabled)
                self.setAutonomyConfiguration(configuration)
            },
            onRefreshUsage: { [weak self] in self?.refreshUsage() },
            onSetStatusItemVisible: { [weak self] visible in
                guard let self else { return }
                self.preferences.showsStatusItem = visible
                self.statusMenu?.setVisible(visible)
                if visible { self.refreshStatusItemSpend() }
            },
            onImportPet: { [weak self] in self?.importPet() },
            onChoosePetsDirectory: { [weak self] in self?.choosePetsDirectory() },
            onSetPetsDirectory: { [weak self] path in
                guard let self else { throw PetsDirectoryError.invalidPath }
                try self.setPetsDirectory(path)
            },
            onRevealPetsDirectory: { [weak self] in self?.revealPetsDirectory() },
            onSetBudgetConfigurations: { [weak self] configurations in
                guard let self else { return }
                self.preferences.budgetConfigurations = configurations
                self.refreshUsage()
            },
            onSetProviderEnabled: { [weak self] provider, enabled in
                guard let self else { return }
                self.preferences.setProviderEnabled(provider, enabled: enabled)
                self.refreshUsage()
            },
            monitorState: { [weak self] in
                guard let self else {
                    return DashboardMonitorState(
                        enabled: false,
                        provider: nil,
                        detections: AgentProvider.allCases.map { ProviderDetection(provider: $0, isDetected: false) }
                    )
                }
                return DashboardMonitorState(
                    enabled: self.preferences.monitorEnabled,
                    provider: self.preferences.monitorProvider,
                    detections: self.monitorProviderDetections()
                )
            },
            onSetMonitor: { [weak self] enabled, provider in
                guard let self else {
                    throw ProviderHookInstallError(
                        provider: provider ?? .cursor,
                        path: FileManager.default.homeDirectoryForCurrentUser.path,
                        reason: "PetRunner is unavailable"
                    )
                }
                if enabled {
                    guard let provider else {
                        throw ProviderHookInstallError(
                            provider: .cursor,
                            path: FileManager.default.homeDirectoryForCurrentUser.path,
                            reason: "Choose a provider before enabling Agent Monitor"
                        )
                    }
                    try self.enableMonitor(provider: provider)
                } else {
                    try self.disableMonitor()
                }
            },
            onResetMonitor: { [weak self] in
                self?.resetMonitorSessions()
            }
        )
        dashboardAPI = api
        let resources = Bundle.main.resourceURL?.appendingPathComponent("DashboardWeb", isDirectory: true)
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("DashboardWeb", isDirectory: true)
            .appendingPathComponent("dist", isDirectory: true)
        let assets = resources.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development
        let server = LocalDashboardServer(assetsDirectory: assets) { [weak api] request in
            guard let api else {
                return .error(status: 503, code: "dashboard_unavailable", message: "Dashboard is unavailable.")
            }
            return await api.response(for: request)
        }
        do {
            _ = try server.start()
            dashboardServer = server
        } catch {
            logger.error("Failed to start dashboard server: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshUsage() {
        guard let usageCoordinator else { return }
        Task { [weak self] in
            let configurations = self?.preferences.budgetConfigurations ?? [:]
            let enabledProviders = self?.preferences.enabledProviders ?? Set(UsageProvider.allCases)
            guard let snapshot = try? await usageCoordinator.refresh(
                configurations: configurations,
                enabledProviders: enabledProviders
            ) else { return }
            await MainActor.run {
                self?.usageSnapshot = snapshot
                self?.refreshStatusItemSpend()
                self?.budgetNotifications.present(snapshot.alerts) { [weak self] animation in
                    self?.refreshMonitorPresentation()
                    self?.overlay.setMonitorAnimation(animation ?? self?.monitorStore.selected?.animation)
                }
            }
        }
    }

    private func configureUsageCoordinator() {
        do {
            usageCoordinator = try UsageCoordinator(storeURL: AgentMonitorBridge.runtimeDirectoryURL.appendingPathComponent("usage-history.sqlite", isDirectory: false))
            refreshUsage()
            usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUsage() }
            }
            if let usageRefreshTimer { RunLoop.main.add(usageRefreshTimer, forMode: .common) }
        } catch {
            logger.error("Failed to open usage history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func importPet() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            _ = try PetImportService().import(source: source, into: petsDirectory)
            reloadPets()
        } catch PetImportError.duplicateRequiresReplacement {
            let alert = NSAlert()
            alert.messageText = "Replace existing pet?"
            alert.informativeText = "PetRunner will keep a local backup of the existing package."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                _ = try PetImportService().import(source: source, into: petsDirectory, replaceExisting: true)
                reloadPets()
            } catch { showImportError(error) }
        } catch { showImportError(error) }
    }

    private func showImportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not import pet"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.runModal()
    }

    private func refreshMonitorPresentation() {
        guard let selected = monitorStore.selected else { sessionBubble.hide(); overlay.setMonitorAnimation(nil); return }
        overlay.setMonitorAnimation(selected.animation)
        sessionBubble.update(
            entries: monitorStore.entries,
            selectedIndex: monitorStore.selectedIndex,
            petFrame: overlay.frame,
            visibleFields: MonitorBubbleField.allCases,
            isCollapsed: preferences.monitorBubbleCollapsed
        )
    }

    private func expireTerminalSession(_ key: AgentSessionKey) {
        let expiry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.terminalSessionExpiry.removeValue(forKey: key)
            if self.monitorStore.remove(key) {
                self.refreshMonitorPresentation()
            }
        }
        terminalSessionExpiry[key] = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentSessionExpiryPolicy.gracePeriod(for: key), execute: expiry)
    }

    private func cancelTerminalExpiry() {
        terminalSessionExpiry.values.forEach { $0.cancel() }
        terminalSessionExpiry.removeAll()
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
            petsDirectoryLockedByCLI = true
            petsDirectorySource = "cli"
            return URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath, isDirectory: true)
        }
        if let preferred = preferences.petsDirectory {
            petsDirectorySource = "preference"
            return preferred
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            petsDirectorySource = "codexHome"
            return URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("pets", isDirectory: true)
        }
        petsDirectorySource = "default"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem(title: "PetRunner", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "PetRunner")
        appMenu.addItem(withTitle: "Open Dashboard", action: #selector(showDashboardFromSecondaryLaunch), keyEquivalent: "o")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PetRunner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; main.addItem(edit)
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.submenu = windowMenu; main.addItem(window)
        NSApp.mainMenu = main
    }
}

private enum PetsDirectoryError: Error, LocalizedError {
    case lockedByCLI
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .lockedByCLI: "Pets directory was set with --pets-dir and cannot be changed while running."
        case .invalidPath: "Choose a valid pets folder path."
        }
    }
}
