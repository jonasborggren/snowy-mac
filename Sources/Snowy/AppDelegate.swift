import AppKit
import SnowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuDelegate {
    private var coordinator: DesktopCoordinator?
    private var statusItem: NSStatusItem?
    private let pauseItem = NSMenuItem(title: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var weatherItems: [NSMenuItem] = []
    private let localWeatherItem = NSMenuItem(title: "Local Weather", action: #selector(toggleLocalWeather), keyEquivalent: "l")
    private let weatherInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var windPopover: NSPopover?
    private var toolItems: [NSMenuItem] = []
    private var welcomeWindow: WelcomeWindowController?
    private var snowyWindow: SnowyWindowController?
    private let decorationSettings = DecorationSettings()
    private let updater = SnowyUpdater()
    private let updateItem = NSMenuItem(title: "Update", action: #selector(installUpdate), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read the persisted domain before coordinator startup can write settings.
        let defaults = UserDefaults.standard
        let domainName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let shouldShowWelcome = FirstLaunchPolicy.shouldPresent(in: defaults, domainName: domainName)
        buildMenu()
        updater.onChange = { [weak self] in self?.updateAvailableRelease() }
        updater.start()
        do {
            let coordinator = try DesktopCoordinator()
            self.coordinator = coordinator
            coordinator.onStateChange = { [weak self] in self?.updateMenu() }
            decorationSettings.onChange = { [weak coordinator] configuration in
                coordinator?.setDecorations(configuration)
            }
            decorationSettings.desktops = coordinator.editorDesktops
            decorationSettings.onEditorVisibility = { [weak coordinator] visible in
                coordinator?.setEditorVisible(visible)
            }
            coordinator.onDesktopGeometryChange = { [weak self] desktops in
                self?.decorationSettings.desktops = desktops
            }
            decorationSettings.apply()
        } catch {
            stateItem.title = "Metal is unavailable on this Mac"
            pauseItem.isEnabled = false
        }
        updateMenu()
        if coordinator != nil {
            FirstLaunchPolicy.markConsidered(in: defaults)
            if shouldShowWelcome { presentWelcome() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let welcomeWindow { welcomeWindow.present() }
        else { presentSnowyWindow() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        welcomeWindow?.close()
        snowyWindow?.close()
        windPopover?.performClose(nil)
        coordinator?.stop()
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowy")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Snowy — desktop snowfall"
        statusItem = item
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let support = NSMenuItem(title: "Drop some coins", action: #selector(openSupportCheckout), keyEquivalent: "")
        support.target = self
        menu.addItem(support)
        menu.addItem(.separator())
        let title = NSMenuItem(title: "Snowy", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Snowy…", action: #selector(openSnowyWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        let clear = NSMenuItem(title: "Clear Settled Snow", action: #selector(clearSnow), keyEquivalent: "k")
        clear.target = self
        menu.addItem(clear)
        let tool = NSMenuItem(title: "Cursor Tool", action: nil, keyEquivalent: "")
        let tools = NSMenu(title: "Cursor Tool")
        tools.autoenablesItems = false
        for (index, name) in ["Glove", "Shovel"].enumerated() {
            let option = NSMenuItem(title: name, action: #selector(selectTool(_:)), keyEquivalent: "")
            option.tag = index
            option.target = self
            tools.addItem(option)
            toolItems.append(option)
        }
        tool.submenu = tools
        menu.addItem(tool)
        menu.addItem(.separator())
        for (index, snowfall) in Snowfall.allCases.enumerated() {
            let option = NSMenuItem(title: snowfall.rawValue, action: #selector(setSnowfall(_:)), keyEquivalent: "")
            option.target = self
            option.tag = index
            weatherItems.append(option)
            menu.addItem(option)
        }
        localWeatherItem.target = self
        localWeatherItem.toolTip = "Snow only when it snows where you are, about as heavily as outside"
        menu.addItem(localWeatherItem)
        weatherInfoItem.isEnabled = false
        weatherInfoItem.indentationLevel = 1
        weatherInfoItem.isHidden = true
        menu.addItem(weatherInfoItem)
        let wind = NSMenuItem(title: "Wind…", action: #selector(showWind), keyEquivalent: "w")
        wind.target = self
        menu.addItem(wind)
        menu.addItem(.separator())
        updateItem.target = self
        updateItem.isHidden = true
        updateItem.isEnabled = false
        menu.addItem(updateItem)
        let quit = NSMenuItem(title: "Quit Snowy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { updateAvailableRelease() }

    private func updateAvailableRelease() {
        guard let version = updater.availableVersion else {
            updateItem.isHidden = true
            return
        }
        updateItem.attributedTitle = NSAttributedString(
            string: "Update to \(version)…",
            attributes: [.foregroundColor: NSColor.linkColor]
        )
        updateItem.isHidden = false
        updateItem.isEnabled = updater.canInstall
    }

    @objc private func installUpdate() { updater.install() }

    @objc private func openSnowyWindow() {
        DispatchQueue.main.async { [weak self] in self?.presentSnowyWindow() }
    }

    private func presentSnowyWindow() {
        if snowyWindow == nil {
            snowyWindow = SnowyWindowController(
                settings: decorationSettings,
                resetDecorations: { [weak self] in self?.coordinator?.resetDecorations() },
                replayWalkthrough: { [weak self] in self?.presentWelcome() }
            )
        }
        snowyWindow?.present()
    }

    private func presentWelcome() {
        if welcomeWindow == nil {
            let welcome = WelcomeWindowController()
            welcome.onClose = { [weak self] in self?.welcomeWindow = nil }
            welcomeWindow = welcome
        }
        welcomeWindow?.present()
    }

    @objc private func openSupportCheckout() {
        guard let url = URL(string: "https://snowy.aauburn.com/#drop-some-coins") else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateMenu() {
        guard let coordinator else { return }
        pauseItem.title = coordinator.paused ? "Resume Snow" : "Pause Snow"
        if coordinator.failed { stateItem.title = "Rendering stopped — relaunch to retry" }
        else if coordinator.policy.suspended { stateItem.title = "Resting while your Mac cools down" }
        else if coordinator.paused { stateItem.title = "Snow is paused" }
        else if coordinator.policy.reducedMotion { stateItem.title = "Quiet drifts · Reduce Motion" }
        else if coordinator.policy.particleScale < 1 { stateItem.title = "Gentle snowfall · saving energy" }
        else { stateItem.title = "Brush a snowy edge to sweep it away" }
        for (index, item) in weatherItems.enumerated() {
            item.state = !coordinator.localWeather && Snowfall.allCases[index] == coordinator.snowfall ? .on : .off
        }
        localWeatherItem.state = coordinator.localWeather ? .on : .off
        weatherInfoItem.isHidden = !coordinator.localWeather
        weatherInfoItem.title = Self.describe(coordinator.weatherStatus)
        for (index, item) in toolItems.enumerated() {
            item.state = (index == 1 ? coordinator.tool == .shovel : coordinator.tool == .glove) ? .on : .off
        }
    }

    @objc private func togglePause() { coordinator?.paused.toggle() }
    @objc private func clearSnow() { coordinator?.clear() }
    @objc private func showWind() {
        // A menu action runs during tracking; show after it closes so the popover receives focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem?.button, let coordinator = self.coordinator else { return }
            if let popover = self.windPopover, popover.isShown { popover.performClose(nil); return }
            let content = WindViewController()
            content.settings = coordinator.wind
            content.onChange = { [weak coordinator] value in coordinator?.wind = value }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentViewController = content
            popover.delegate = self
            content.onClose = { [weak popover] in popover?.performClose(nil) }
            self.windPopover = popover
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === windPopover else { return }
        windPopover = nil
    }

    @objc private func selectTool(_ sender: NSMenuItem) {
        coordinator?.tool = sender.tag == 1 ? .shovel : .glove
    }
    @objc private func setSnowfall(_ sender: NSMenuItem) {
        guard Snowfall.allCases.indices.contains(sender.tag) else { return }
        coordinator?.localWeather = false
        coordinator?.snowfall = Snowfall.allCases[sender.tag]
    }
    @objc private func toggleLocalWeather() {
        guard let coordinator else { return }
        coordinator.localWeather.toggle()
        // Opening the menu again after enabling it is a natural moment to want fresh data.
        if coordinator.localWeather { coordinator.refreshWeather() }
    }

    private static func describe(_ status: WeatherService.Status) -> String {
        switch status {
        case .idle, .locating: return "Finding your weather…"
        case .locationDenied: return "Allow Location in System Settings → Privacy"
        case .unavailable(let message): return message
        case .reading(let reading):
            let temperature = String(format: "%.0f°C", reading.temperature)
            guard reading.isSnowing else { return "Not snowing outside · \(temperature)" }
            let intensity: String = switch reading.snowDensity {
            case ..<0.7: "Light snow"
            case ..<1.3: "Moderate snow"
            default: "Heavy snow"
            }
            if reading.snowfallPerHour >= 0.05 {
                return String(format: "%@ · %.1f cm/h · %@", intensity, reading.snowfallPerHour, temperature)
            }
            return "\(intensity) · \(temperature)"
        }
    }
}
