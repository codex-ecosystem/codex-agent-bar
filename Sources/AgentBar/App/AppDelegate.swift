import AppKit
import Combine
import Darwin
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = QuotaStore()
    private let updateCoordinator = AppUpdateCoordinator()
    private var statusItem: NSStatusItem?
    private var menuBarView: MenuBarQuotaView?
    private var popover: NSPopover?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastShownCLIUpgradeAlertMessage: String?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let logger = Logger(subsystem: "com.lonewolfyx.AgentBar", category: "Lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppIcon.image()
        updateCoordinator.start()
        configureStatusItem()
        bindStore()
        bindSystemLifecycle()
        monitorMemoryPressure()
        logger.info("AgentBar started on \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
        updateMenuBarTitle()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        closePopover(nil)
        cancellables.removeAll()
        store.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Keep the run loop alive until the owned child has received its termination signal.
        store.stop {
            Task { @MainActor in
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func bindSystemLifecycle() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.closePopover(nil)
                self?.store.suspend(for: .systemSleep)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.store.resume(after: .systemSleep)
            }
            .store(in: &cancellables)
    }

    private func monitorMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressureSource?.data else {
                    return
                }

                if event.contains(.critical) || event.contains(.warning) {
                    let isCritical = event.contains(.critical)
                    let level = isCritical ? "critical" : "warning"
                    let action = isCritical ? "pausing quota refresh" : "releasing idle resources"
                    let footprint = self.physicalMemoryFootprint().map { "\($0 / 1_048_576) MiB" } ?? "unavailable"
                    self.logger.notice("System memory pressure: \(level, privacy: .public); \(action, privacy: .public). AgentBar physical footprint: \(footprint, privacy: .public)")
                    self.closePopover(nil)
                    if isCritical {
                        self.store.suspend(for: .memoryPressure)
                    } else {
                        self.store.releaseIdleResources()
                    }
                } else if event.contains(.normal) {
                    self.logger.info("System memory pressure returned to normal")
                    self.store.resume(after: .memoryPressure)
                }
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    private func physicalMemoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else {
            return
        }

        let view = MenuBarQuotaView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 0,
                height: NSStatusBar.system.thickness
            )
        )
        item.length = view.preferredWidth
        view.target = self
        view.action = #selector(togglePopover(_:))
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        menuBarView = view
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: store.displaysFiveHourQuota ? 624 : 520)
        popover.contentViewController = VisualEffectHostingController(
            rootView: QuotaPopoverView(
                store: store,
                updateCoordinator: updateCoordinator,
                onAbout: {
                    guard let url = URL(string: "http://github.com/lonewolfyx/codex-agent-bar") else {
                        return
                    }

                    NSWorkspace.shared.open(url)
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
        self.popover = popover
    }

    private func bindStore() {
        NotificationCenter.default.publisher(for: AppUpdateNotificationService.notificationActivated)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                NSApp.activate(ignoringOtherApps: true)
                self?.updateCoordinator.presentCurrentUpdate()
            }
            .store(in: &cancellables)

        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBarTitle()
            }
            .store(in: &cancellables)

        store.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBarTitle()
            }
            .store(in: &cancellables)

        store.$currentAccount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBarTitle()
            }
            .store(in: &cancellables)

        store.$cliUpgradeAlertMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.showCLIUpgradeAlertIfNeeded(message)
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarTitle() {
        guard let menuBarView else {
            return
        }

        menuBarView.update(
            snapshot: store.snapshot,
            displaysFiveHourQuota: store.displaysFiveHourQuota,
            statusMessage: store.statusMessage
        )

        popover?.contentSize.height = store.displaysFiveHourQuota ? 624 : 520

        let preferredWidth = menuBarView.preferredWidth
        if statusItem?.length != preferredWidth {
            statusItem?.length = preferredWidth
        }
    }

    private func showCLIUpgradeAlertIfNeeded(_ message: String?) {
        guard
            let message,
            !message.isEmpty,
            message != lastShownCLIUpgradeAlertMessage
        else {
            return
        }

        lastShownCLIUpgradeAlertMessage = message
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = I18n.current.codexCLIUpgradeAlertTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func togglePopover(_ sender: NSControl) {
        if popover == nil {
            configurePopover()
        }

        guard let popover else {
            return
        }

        if popover.isShown {
            closePopover(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            installOutsideClickMonitors()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
        // Hidden SwiftUI charts and tracking views should not observe every background refresh.
        popover?.contentViewController = nil
        popover = nil
    }

    private func closePopover(_ sender: Any?) {
        popover?.performClose(sender)
        removeOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else {
                return event
            }

            if self.shouldClosePopover(for: event) {
                self.closePopover(event)
            }

            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopover(event)
        }
    }

    private func removeOutsideClickMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func shouldClosePopover(for event: NSEvent) -> Bool {
        guard popover?.isShown == true else {
            return false
        }

        if let menuBarView, containsEventLocation(event, in: menuBarView) {
            return false
        }

        if let popoverView = popover?.contentViewController?.view, containsEventLocation(event, in: popoverView) {
            return false
        }

        return true
    }

    private func containsEventLocation(_ event: NSEvent, in view: NSView) -> Bool {
        guard let window = view.window else {
            return false
        }

        let pointInWindow = event.window === window
            ? event.locationInWindow
            : window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInView = view.convert(pointInWindow, from: nil)
        return view.bounds.contains(pointInView)
    }

}

private final class VisualEffectHostingController<Content: View>: NSViewController {
    private let rootView: Content
    private var hostingController: NSHostingController<Content>?

    init(rootView: Content) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hostingController)
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        self.hostingController = hostingController
    }
}
