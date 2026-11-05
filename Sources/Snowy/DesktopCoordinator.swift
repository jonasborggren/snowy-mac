import AppKit
import MetalKit
import SnowCore

private final class SnowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopCoordinator {
    var onStateChange: (() -> Void)?
    var onDesktopGeometryChange: (([SceneDesktop]) -> Void)?
    private(set) var failed = false
    private(set) var policy: RenderPolicy
    var paused: Bool {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            updateState()
        }
    }
    var snowfall: Snowfall {
        didSet {
            UserDefaults.standard.set(snowfall.rawValue, forKey: "snowfall")
            for display in displays { display.renderer.simulation.snowfall = snowfall }
            onStateChange?()
        }
    }
    /// Follow the weather where the Mac is, instead of the chosen preset.
    var localWeather: Bool {
        didSet {
            UserDefaults.standard.set(localWeather, forKey: "localWeather")
            if localWeather { weather.start() } else { weather.stop() }
            applyWeather()
        }
    }
    var weatherStatus: WeatherService.Status { weather.status }
    /// The density local weather asks for, or nil while it's off or not yet known.
    var weatherDensity: Float? {
        guard localWeather else { return nil }
        switch weather.status {
        case .reading(let reading): return reading.snowDensity
        case .locationDenied, .unavailable: return 0
        case .idle, .locating: return 0
        }
    }
    private let weather = WeatherService()
    var wind: WindSettings {
        didSet {
            UserDefaults.standard.set(wind.vector.x, forKey: "windX")
            UserDefaults.standard.set(wind.vector.y, forKey: "windY")
            for display in displays { display.renderer.simulation.wind = wind }
            onStateChange?()
        }
    }
    var tool: SnowTool {
        didSet {
            UserDefaults.standard.set(tool.rawValue, forKey: "cursorTool")
            for display in displays { display.renderer.simulation.tool = tool }
            onStateChange?()
        }
    }
    private let context: MetalContext
    private let tracker = WindowTracker()
    private var displays: [Display] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var metadataTimer: Timer?
    private var screensAwake = true
    private var sessionActive = true
    private var primaryTop: CGFloat = 0
    private var reconfiguring = false
    private var stopping = false
    private var updatingState = false
    private var draggingWindow = false
    private var lastDockGeometryRead: CFTimeInterval = -.infinity
    private var dockBottomInsets: [UInt32: Float] = [:]
    private var decorationConfiguration = DecorationConfiguration()
    private var editorVisible = false

    var editorDesktops: [SceneDesktop] { displays.map(\.desktop) }

    @MainActor
    private final class Display {
        let geometry: DisplayGeometry
        let panel: SnowPanel
        let renderer: MetalRenderer
        let nativeScale: CGFloat
        let decorations: DesktopDecorations
        let lights: DesktopHangingLights
        var snapshot: DisplaySnapshot?
        var fullscreen = false
        var geometryReady = false
        var desktop: SceneDesktop {
            snapshot?.desktop ?? SceneDesktop(id: geometry.id, size: geometry.bounds.size, dock: nil, anchors: [])
        }

        init(geometry: DisplayGeometry, panel: SnowPanel, renderer: MetalRenderer, nativeScale: CGFloat,
             decorations: DesktopDecorations, lights: DesktopHangingLights) {
            self.geometry = geometry
            self.panel = panel
            self.renderer = renderer
            self.nativeScale = nativeScale
            self.decorations = decorations
            self.lights = lights
        }
    }

    init() throws {
        context = try MetalContext()
        paused = UserDefaults.standard.bool(forKey: "paused")
        snowfall = Snowfall(rawValue: UserDefaults.standard.string(forKey: "snowfall") ?? "") ?? .steady
        wind = WindSettings(vector: SIMD2(UserDefaults.standard.float(forKey: "windX"),
                                         UserDefaults.standard.float(forKey: "windY")))
        tool = SnowTool(rawValue: UserDefaults.standard.string(forKey: "cursorTool") ?? "") ?? .glove
        localWeather = UserDefaults.standard.bool(forKey: "localWeather")
        policy = Self.readPolicy()
        weather.onChange = { [weak self] _ in self?.applyWeather() }
        installObservers()
        configureDisplays()
        if localWeather { weather.start() }
    }

    func refreshWeather() { weather.refresh() }

    private func applyWeather() {
        let density = weatherDensity
        for display in displays { display.renderer.simulation.weatherDensity = density }
        onStateChange?()
    }

    func clear() {
        for display in displays { display.renderer.simulation.clear() }
    }

    func setDecorations(_ configuration: DecorationConfiguration) {
        decorationConfiguration = configuration
        for display in displays {
            configureDecorations(for: display)
            applyScene(for: display)
        }
        updateIconTracking()
        updateState()
    }

    func setEditorVisible(_ visible: Bool) {
        editorVisible = visible
        updateIconTracking()
        updateState()
    }

    func resetDecorations() {
        for display in displays {
            display.decorations.reset()
            display.lights.configure([])
            display.lights.configure(decorationConfiguration.scene(for: display.desktop).lights)
            applyScene(for: display)
        }
        updateState()
    }

    func stop() {
        stopping = true
        weather.stop()
        metadataTimer?.invalidate()
        metadataTimer = nil
        tracker.invalidate()
        for display in displays {
            display.renderer.view.isPaused = true
            display.renderer.spotlightOverlay.close()
            display.panel.close()
        }
        displays.removeAll()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private static func readPolicy() -> RenderPolicy {
        let process = ProcessInfo.processInfo
        return RenderPolicy(lowPower: process.isLowPowerModeEnabled,
                            thermalLevel: process.thermalState.rawValue,
                            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor @Sendable () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, observer))
    }

    private func installObservers() {
        let notifications = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observe(notifications, .NSProcessInfoPowerStateDidChange) { [weak self] in self?.refreshPolicy() }
        observe(notifications, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.refreshPolicy() }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.refreshPolicy() }
        observe(notifications, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.configureDisplays() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            guard let self else { return }
            self.tracker.invalidate()
            // Don't carry snow from another Space onto a reused window ID.
            for display in self.displays {
                display.snapshot = nil
                display.geometryReady = false
                display.renderer.spotlightOverlay.update(supports: [], displayBounds: display.geometry.bounds,
                                                        primaryTop: self.primaryTop)
                display.renderer.simulation.updateSurfaces([])
                display.renderer.simulation.updateBodies([])
                display.renderer.simulation.clear()
                display.renderer.simulation.resetPointer()
            }
            self.updateState()
            self.refreshMetadata()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.screensAwake = false
            self?.updateState()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.screensAwake = true
            self?.tracker.invalidate()
            self?.updateState()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.sessionActive = false
            self?.updateState()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.sessionActive = true
            self?.tracker.invalidate()
            self?.updateState()
        }
    }

    private func refreshPolicy() {
        policy = Self.readPolicy()
        updateState()
    }

    private func configureDisplays() {
        reconfiguring = true
        tracker.invalidate()
        lastDockGeometryRead = -.infinity
        dockBottomInsets.removeAll(keepingCapacity: true)
        for display in displays {
            display.renderer.view.isPaused = true
            display.renderer.spotlightOverlay.close()
            display.panel.close()
        }
        displays.removeAll()
        let screens = Array(NSScreen.screens.prefix(6))
        guard let primary = screens.first else {
            reconfiguring = false
            updateState()
            return
        }
        primaryTop = primary.frame.maxY
        let totalArea = max(1, screens.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height })
        let totalFlakes = min(900, max(80, Int(totalArea / 1_000_000 * 180)))
        do {
            for screen in screens {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let frame = screen.frame
                let visible = screen.visibleFrame
                let share = frame.width * frame.height / totalArea
                let geometry = DisplayGeometry(
                    id: id.uint32Value,
                    bounds: CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height),
                    menuInset: Float(max(0, frame.maxY - visible.maxY)),
                    dockBottomInset: Float(max(0, visible.minY - frame.minY))
                )
                let budget = SimulationBudget(flakes: Int(CGFloat(totalFlakes) * share),
                                              debris: Int(192 * share), cells: Int(4096 * share),
                                              surfaces: Int(48 * share))
                let renderer = try MetalRenderer(context: context, size: frame.size, menuInset: geometry.menuInset,
                                                 budget: budget, seed: UInt64(geometry.id))
                renderer.simulation.snowfall = snowfall
                renderer.simulation.weatherDensity = weatherDensity
                renderer.simulation.wind = wind
                renderer.simulation.tool = tool
                let panel = SnowPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.isMovable = false
                panel.animationBehavior = .none
                // Immediately above wallpaper, below desktop icons/widgets and all app windows.
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.isExcludedFromWindowsMenu = true
                let decorations = DesktopDecorations(size: frame.size)
                let lights = DesktopHangingLights(size: frame.size)
                let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
                renderer.view.autoresizingMask = [.width, .height]
                content.addSubview(renderer.view)
                // Like desktop windows, opaque sprite pixels cover snow behind
                // them while leaving their transparent outline and tops visible.
                content.addSubview(decorations.view)
                content.addSubview(lights.view)
                panel.contentView = content
                panel.setFrame(frame, display: false)
                let display = Display(geometry: geometry, panel: panel, renderer: renderer,
                                      nativeScale: screen.backingScaleFactor, decorations: decorations, lights: lights)
                configureDecorations(for: display)
                renderer.cursorPosition = { [weak self] in
                    let point = NSEvent.mouseLocation
                    return SIMD2(Float(point.x - geometry.bounds.minX),
                                 Float((self?.primaryTop ?? 0) - point.y - geometry.bounds.minY))
                }
                renderer.beforeFrame = { [weak self, weak display] now, cursor in
                    guard let self else { return }
                    let down = NSEvent.pressedMouseButtons != 0
                    if down || self.draggingWindow { self.refreshMetadata(dragging: down) }
                    self.draggingWindow = down
                    guard let display, let snapshot = display.snapshot else { return }
                    let pointer = down ? nil : cursor
                    let isCoveredByOwnWindow: (SIMD2<Float>) -> Bool = { point in
                        let global = CGPoint(x: geometry.bounds.minX + CGFloat(point.x),
                                             y: self.primaryTop - geometry.bounds.minY - CGFloat(point.y))
                        return NSApp.windows.contains {
                            $0.isVisible && $0.level.rawValue >= NSWindow.Level.normal.rawValue
                                && $0.frame.contains(global)
                        }
                    }
                    display.lights.advance(now: now, wind: self.wind, cursor: pointer,
                                           reducedMotion: self.policy.reducedMotion) { point in
                        snapshot.bodies.contains { $0.contains(point) } || isCoveredByOwnWindow(point)
                    }
                    if display.decorations.advance(cursor: pointer, now: now,
                                                   reducedMotion: self.policy.reducedMotion, occluders: snapshot.bodies,
                                                   isCoveredByOwnWindow: isCoveredByOwnWindow) {
                        self.applyScene(for: display)
                    }
                }
                renderer.onFailure = { [weak self] in
                    self?.failed = true
                    self?.updateState()
                }
                displays.append(display)
            }
        } catch {
            failed = true
        }
        reconfiguring = false
        updateIconTracking()
        onDesktopGeometryChange?(editorDesktops)
        updateState()
    }

    private var desktopAvailable: Bool { screensAwake && sessionActive && !failed && !policy.suspended }
    private var running: Bool { !paused && desktopAvailable }
    private var followsObjects: Bool {
        displays.contains { $0.lights.followsWidgets || (tracker.includesDesktopIcons && $0.lights.followsIcons) }
    }
    private var needsDesktopScene: Bool {
        desktopAvailable && (!paused || editorVisible || decorationConfiguration.hasContent)
    }

    private func updateIconTracking() {
        let needed = decorationConfiguration.includesDesktopIcons
            && (editorVisible || displays.contains { $0.lights.followsIcons })
        guard needed != tracker.includesDesktopIcons else { return }
        tracker.includesDesktopIcons = needed
        refreshMetadata()
    }

    private func configureDecorations(for display: Display) {
        let desktop = display.desktop
        let scene = decorationConfiguration.scene(for: desktop)
        display.decorations.updateDock(desktop.dock)
        display.decorations.configure(props: scene.props)
        display.lights.updateDesktop(desktop, animate: running && !policy.reducedMotion && !display.fullscreen)
        display.lights.configure(scene.lights)
    }

    private func applyScene(for display: Display) {
        guard let snapshot = display.snapshot else { return }
        let simulation = display.renderer.simulation
        let scene = display.decorations.scene(with: snapshot, budget: simulation.budget)
        simulation.updateScene(surfaces: scene.surfaces, bodies: scene.bodies)
    }

    private func updateState() {
        guard !reconfiguring, !stopping, !updatingState else { return }
        updatingState = true
        defer { updatingState = false }
        let totalArea = max(1, displays.reduce(CGFloat(0)) {
            $0 + $1.geometry.bounds.width * $1.geometry.bounds.height + $1.renderer.spotlightOverlay.logicalArea
        })
        // Across every display, limit drawable area as well as particle/mesh counts.
        let pixelBudgetScale = sqrt(6_000_000 / totalArea)
        for display in displays {
            // Seed airborne flakes only after the first body snapshot, never inside unknown windows.
            let visibleDesktop = desktopAvailable && display.geometryReady && !display.fullscreen
            let showSnow = running && visibleDesktop
            let showDecorations = visibleDesktop && (!display.decorations.isEmpty || !display.lights.isEmpty)
            if showSnow || showDecorations {
                if !display.panel.isVisible { display.panel.orderFrontRegardless() }
            } else if display.panel.isVisible { display.panel.orderOut(nil) }
            display.renderer.view.isHidden = !showSnow
            let scale = min(display.nativeScale, min(CGFloat(policy.renderScale), pixelBudgetScale))
            // Full-display transparent Finder/widget containers can mark a desktop panel occluded.
            // Use explicit scene/lifecycle gates; that bounding-box signal is not reliable here.
            display.renderer.apply(policy: policy, scale: scale, paused: !showSnow)
            display.renderer.spotlightOverlay.apply(show: showSnow, scale: scale)
        }
        if desktopAvailable && (running || editorVisible || followsObjects) && !displays.isEmpty {
            if metadataTimer == nil {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshMetadata() }
                }
                timer.tolerance = 0.10
                RunLoop.main.add(timer, forMode: .common)
                metadataTimer = timer
                refreshMetadata()
            }
        } else {
            metadataTimer?.invalidate()
            metadataTimer = nil
            if needsDesktopScene {
                // A paused desktop needs only a one-shot snapshot after a Space
                // or display change. Its static art requires no render clock.
                if displays.contains(where: { !$0.geometryReady }) { refreshMetadata() }
            } else {
                tracker.invalidate()
            }
        }
        onStateChange?()
    }

    private func refreshMetadata(dragging: Bool? = nil) {
        guard needsDesktopScene, !displays.isEmpty else { return }
        let idleInterval: TimeInterval = displays.allSatisfy(\.fullscreen) ? 1 : 0.5
        let now = CACurrentMediaTime()
        if now - lastDockGeometryRead >= idleInterval {
            // visibleFrame follows the currently occupied Dock screen and auto-hide
            // state. Re-read it at metadata cadence, without rebuilding renderers.
            dockBottomInsets.removeAll(keepingCapacity: true)
            for screen in NSScreen.screens.prefix(6) {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let frame = screen.frame
                dockBottomInsets[id.uint32Value] = Float(max(0, screen.visibleFrame.minY - frame.minY))
            }
            lastDockGeometryRead = now
        }
        let geometry = displays.map { display in
            DisplayGeometry(id: display.geometry.id, bounds: display.geometry.bounds,
                            menuInset: display.geometry.menuInset,
                            dockBottomInset: dockBottomInsets[display.geometry.id] ?? 0)
        }
        tracker.refreshIfNeeded(displays: geometry, now: now,
                                dragging: dragging ?? (NSEvent.pressedMouseButtons != 0), idleInterval: idleInterval) { [weak self] snapshots in
            guard let self, self.needsDesktopScene else { return }
            guard let snapshots else {
                self.refreshMetadata()
                return
            }
            let previousDesktops = self.editorDesktops
            for snapshot in snapshots {
                guard let display = self.displays.first(where: { $0.geometry.id == snapshot.id }) else { continue }
                let previousSnapshot = display.snapshot
                let previousDesktop = display.desktop
                display.snapshot = snapshot
                let desktopChanged = display.desktop != previousDesktop
                if desktopChanged { self.configureDecorations(for: display) }
                if desktopChanged || previousSnapshot?.surfaces != snapshot.surfaces
                    || previousSnapshot?.bodies != snapshot.bodies {
                    self.applyScene(for: display)
                }
                display.renderer.spotlightOverlay.update(supports: snapshot.spotlightSupports,
                                                        displayBounds: display.geometry.bounds, primaryTop: self.primaryTop)
                display.fullscreen = snapshot.fullscreen
                display.geometryReady = true
            }
            let newDesktops = self.editorDesktops
            if newDesktops != previousDesktops { self.onDesktopGeometryChange?(newDesktops) }
            self.updateState()
        }
    }
}
