import AppKit
import SniffCore
import Observation
import SniffIdentity

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: AppStore
    private let showWindow: () -> Void
    private let showSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: 42)
    private let idle = MenuBarDogImages.idle()
    private let frames = MenuBarDogImages.animation()
    private var timer: Timer?
    private var frame = 0
    private var scheduledPID: Int32?
    private var scheduledCleaning = false
    private var workerCheck: Timer?
    private(set) var displayedAnimationFrames = 0
    var isAnimating: Bool { timer != nil }

    init(store: AppStore, showWindow: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.store = store; self.showWindow = showWindow; self.showSettings = showSettings
        super.init()
        item.button?.imagePosition = .imageOnly
        item.button?.identifier = NSUserInterfaceItemIdentifier("SniffMenuBarDog")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(scheduledActivityChanged(_:)), name: ScheduledActivity.notification, object: nil, suspensionBehavior: .deliverImmediately)
        observeOperation()
    }

    private func observeOperation() {
        withObservationTracking {
            _ = store.busy
            _ = store.canCancel
            _ = store.language
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOperation() }
        }
        updateAnimation()
    }

    private func updateAnimation() {
        let working = store.busy || scheduledPID != nil
        let analyzing = store.busy ? store.canCancel : !scheduledCleaning
        let label = working ? (analyzing ? L("Sniff: Analisando") : L("Sniff: Limpando")) : L("Sniff: Pronto")
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
        guard working && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            timer?.invalidate(); timer = nil; frame = 0
            item.button?.image = idle
            return
        }
        guard timer == nil else { return }
        frame = 0
        item.button?.image = frames[0]
        let clock = Timer(timeInterval: 1 / MenuBarDogImages.framesPerSecond, target: self, selector: #selector(advanceFrame), userInfo: nil, repeats: true)
        clock.tolerance = 0.012
        timer = clock
        // The dog keeps moving when its menu is open, as well as with the main window closed.
        RunLoop.main.add(clock, forMode: .common)
    }

    @objc private func advanceFrame() {
        frame = (frame + 1) % frames.count
        displayedAnimationFrames += 1
        item.button?.image = frames[frame]
    }
    @objc private func accessibilityChanged() { updateAnimation() }

    @objc private func scheduledActivityChanged(_ notification: Notification) {
        guard let value = notification.userInfo?["pid"] as? Int,
              value > 0, value <= Int32.max, value != ProcessInfo.processInfo.processIdentifier,
              let active = notification.userInfo?["active"] as? Bool else { return }
        let pid = Int32(value)
        if active {
            guard kill(pid, 0) == 0 else { return }
            scheduledPID = pid
            scheduledCleaning = notification.userInfo?["cleaning"] as? Bool ?? false
            workerCheck?.invalidate()
            let check = Timer(timeInterval: 1, target: self, selector: #selector(checkScheduledWorker), userInfo: nil, repeats: true)
            check.tolerance = 0.2
            workerCheck = check; RunLoop.main.add(check, forMode: .common)
        } else if scheduledPID == pid {
            scheduledPID = nil; workerCheck?.invalidate(); workerCheck = nil
        }
        updateAnimation()
    }

    @objc private func checkScheduledWorker() {
        if let pid = scheduledPID, kill(pid, 0) != 0, errno == ESRCH {
            scheduledPID = nil; workerCheck?.invalidate(); workerCheck = nil; updateAnimation()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let working = store.busy || scheduledPID != nil
        let analyzing = store.busy ? store.canCancel : !scheduledCleaning
        let status = NSMenuItem(title: working ? (analyzing ? L("Analisando…") : L("Limpando…")) : L("{0} para revisar", Display.items(store.readyCount)), action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        menu.addItem(.separator())
        add(L("Abrir Sniff"), action: #selector(openWindow), to: menu)
        add(L("Analisar agora"), action: #selector(analyze), to: menu, enabled: !working)
        add(L("Ajustes…"), action: #selector(openSettings), to: menu)
        menu.addItem(.separator())
        add(L("Sair do Sniff"), action: #selector(quit), key: "q", to: menu, enabled: !working)
    }
    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu, enabled: Bool = true) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; entry.isEnabled = enabled; menu.addItem(entry)
    }
    @objc private func openWindow() { showWindow(); NSApp.activate(ignoringOtherApps: true) }
    @objc private func analyze() { openWindow(); store.scan() }
    @objc private func openSettings() { showSettings(); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    func invalidate() {
        timer?.invalidate(); timer = nil
        workerCheck?.invalidate(); workerCheck = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSStatusBar.system.removeStatusItem(item)
    }

    func validationSnapshot() -> [String: Any] {
        ["visible": item.isVisible,
         "buttonWindowVisible": item.button?.window?.isVisible ?? false,
         "imageIsTemplate": item.button?.image?.isTemplate ?? false,
         "imageWidth": item.button?.image?.size.width ?? 0,
         "imageHeight": item.button?.image?.size.height ?? 0,
         "accessibleLabel": item.button?.accessibilityLabel() ?? "",
         "distinctFrames": Set(frames.compactMap(\.tiffRepresentation)).count]
    }
}
