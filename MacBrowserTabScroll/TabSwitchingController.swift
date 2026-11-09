import AppKit
import ApplicationServices
import Combine
import ServiceManagement

@MainActor
final class TabSwitchingController: ObservableObject {
    enum Status {
        case off, active, accessibility, inputMonitoring, shortcutAccess, failed

        var message: String {
            switch self {
            case .off: "Tab switching is off."
            case .active: "Scroll over your browser tabs to switch between them."
            case .accessibility: "Allow Accessibility access to switch tabs."
            case .inputMonitoring: "Allow Input Monitoring, then reopen TabScroll."
            case .shortcutAccess: "Allow TabScroll to send keyboard shortcuts."
            case .failed: "TabScroll couldn’t start listening for scrolls."
            }
        }
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var status: Status = .off
    @Published private(set) var lastScrollResult = "Scroll over a browser tab to check."
    @Published private(set) var showsTroubleshooting = false

    func toggleTroubleshooting() -> Bool {
        guard !isRecordingShortcut else { return false }
        showsTroubleshooting.toggle()
        return true
    }
    @Published private(set) var loginStatus = SMAppService.Status.notRegistered
    @Published private(set) var loginError: String?
    @Published var sensitivity: Double {
        didSet {
            defaults.set(sensitivity, forKey: "trackpadSensitivity")
            resetGesture()
        }
    }
    @Published var reverseDirection: Bool {
        didSet {
            defaults.set(reverseDirection, forKey: "reverseDirection")
            resetGesture()
        }
    }
    @Published var singleTabMode: Bool {
        didSet {
            defaults.set(singleTabMode, forKey: "singleTabMode")
            resetGesture()
        }
    }
    @Published private(set) var scrollShortcut: ScrollShortcut
    enum ShortcutAction: String {
        case scrollAnywhere = "scrollShortcut"
        case toggleSingleTab = "toggleSingleTabShortcut"
        case holdSingleTab = "holdSingleTabShortcut"
    }

    @Published private(set) var toggleSingleTabShortcut: ScrollShortcut?
    @Published private(set) var holdSingleTabShortcut: ScrollShortcut?
    @Published private(set) var recordingAction: ShortcutAction?
    var isRecordingShortcut: Bool { recordingAction != nil }
    var canSaveShortcut: Bool {
        guard let recordedShortcut, let recordingAction else { return false }
        return recordingAction != .toggleSingleTab || !recordedShortcut.keys.isEmpty
    }
    @Published private(set) var recordedShortcut: ScrollShortcut?

    @Published var modifierScrollEnabled: Bool {
        didSet {
            defaults.set(modifierScrollEnabled, forKey: "modifierScrollEnabled")
            resetGesture()
        }
    }
    static let maximumCooldownMilliseconds: Double = 1_000
    private static let defaultCooldownMilliseconds: Double = 20

    @Published private(set) var cooldownMilliseconds: Double {
        didSet {
            defaults.set(cooldownMilliseconds, forKey: "cooldownMilliseconds")
            gesture.resetAccumulation()
        }
    }
    @Published private var disabledBrowsers: Set<String>

    private let defaults: UserDefaults
    private let detector = BrowserTabDetector()
    private static let postedShortcutTag: Int64 = 0x5461625363726F6C
    private var gesture = ScrollGesture()
    private var gestureTarget: (pid: pid_t, window: AXUIElement, modifierScroll: Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pendingShortcut: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "trackpadSensitivity": 40.0, "reverseDirection": true,
            "cooldownMilliseconds": Self.defaultCooldownMilliseconds
        ])
        enabled = defaults.bool(forKey: "tabSwitchingEnabled")
        sensitivity = min(max(defaults.double(forKey: "trackpadSensitivity"), 10), 70)
        reverseDirection = defaults.bool(forKey: "reverseDirection")
        singleTabMode = defaults.bool(forKey: "singleTabMode")
        modifierScrollEnabled = defaults.bool(forKey: "modifierScrollEnabled")
        scrollShortcut = Self.loadShortcut(.scrollAnywhere, defaults: defaults) ?? .standard
        toggleSingleTabShortcut = Self.loadShortcut(.toggleSingleTab, defaults: defaults)
        holdSingleTabShortcut = Self.loadShortcut(.holdSingleTab, defaults: defaults)
        let savedCooldown = defaults.double(forKey: "cooldownMilliseconds")
        cooldownMilliseconds = Self.normalizedCooldown(savedCooldown)
        disabledBrowsers = Set(defaults.stringArray(forKey: "disabledBrowsers") ?? [])
        if enabled { start() }
    }

    func beginShortcutRecording(_ action: ShortcutAction) {
        resetGesture()
        recordedShortcut = nil
        recordingAction = action
    }

    func captureShortcut(_ shortcut: ScrollShortcut) {
        guard isRecordingShortcut else { return }
        recordedShortcut = shortcut
    }

    func saveRecordedShortcut() {
        guard canSaveShortcut, let recordedShortcut, let recordingAction,
              let data = try? JSONEncoder().encode(recordedShortcut) else { return }
        defaults.set(data, forKey: recordingAction.rawValue)
        switch recordingAction {
        case .scrollAnywhere: scrollShortcut = recordedShortcut
        case .toggleSingleTab:
            let shouldRestart = toggleSingleTabShortcut == nil
            toggleSingleTabShortcut = recordedShortcut
            if shouldRestart {
                stop()
                start()
            }
        case .holdSingleTab: holdSingleTabShortcut = recordedShortcut
        }
        cancelShortcutRecording()
    }

    func clearSingleTabShortcut(_ action: ShortcutAction) {
        switch action {
        case .scrollAnywhere: return
        case .toggleSingleTab:
            toggleSingleTabShortcut = nil
            stop()
            start()
        case .holdSingleTab:
            holdSingleTabShortcut = nil
            resetGesture()
        }
        defaults.removeObject(forKey: action.rawValue)
    }

    private static func loadShortcut(_ action: ShortcutAction, defaults: UserDefaults) -> ScrollShortcut? {
        guard let data = defaults.data(forKey: action.rawValue),
              let shortcut = try? JSONDecoder().decode(ScrollShortcut.self, from: data),
              !shortcut.isEmpty else { return nil }
        return shortcut
    }

    func cancelShortcutRecording() {
        recordingAction = nil
        recordedShortcut = nil
    }

    func setCooldownMilliseconds(_ value: Double) {
        cooldownMilliseconds = Self.normalizedCooldown(value)
    }

    private static func normalizedCooldown(_ value: Double) -> Double {
        guard value.isFinite else { return defaultCooldownMilliseconds }
        let bounded = min(max(value, 0), maximumCooldownMilliseconds)
        return (bounded * 10).rounded() / 10
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: "tabSwitchingEnabled")
        if enabled {
            start()
        } else {
            stop()
            status = .off
        }
    }

    func isBrowserEnabled(_ browser: Browser) -> Bool {
        !disabledBrowsers.contains(browser.rawValue)
    }

    func setBrowserEnabled(_ enabled: Bool, for browser: Browser) {
        if enabled {
            disabledBrowsers.remove(browser.rawValue)
        } else {
            disabledBrowsers.insert(browser.rawValue)
        }
        defaults.set(disabledBrowsers.sorted(), forKey: "disabledBrowsers")
        resetGesture()
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn’t change Launch at Login. \(error.localizedDescription)"
        }
        loginStatus = service.status
    }

    func start() {
        guard enabled, tap == nil else { return }
        guard AXIsProcessTrusted() else {
            status = .accessibility
            return
        }
        guard CGPreflightPostEventAccess() else {
            status = .shortcutAccess
            return
        }

        var mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        if toggleSingleTabShortcut != nil {
            mask |= CGEventMask(1) << CGEventType.keyDown.rawValue
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                // The tap is installed on the main run loop below.
                let consume = MainActor.assumeIsolated {
                    guard let context else { return false }
                    let controller = Unmanaged<TabSwitchingController>.fromOpaque(context).takeUnretainedValue()
                    return controller.handle(type, event: event)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = CGPreflightListenEventAccess() ? .failed : .inputMonitoring
            return
        }

        guard let newSource = CFMachPortCreateRunLoopSource(nil, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            status = .failed
            return
        }

        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        status = .active
    }

    func requestPermission() {
        switch status {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .shortcutAccess:
            _ = CGRequestPostEventAccess()
        default:
            return
        }
        start()
    }

    private func stop() {
        resetGesture()
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func resetGesture() {
        pendingShortcut?.cancel()
        pendingShortcut = nil
        gesture = ScrollGesture()
        gestureTarget = nil
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            resetGesture()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            return handleTabScroll(event)
        case .keyDown:
            guard !isRecordingShortcut, let shortcut = toggleSingleTabShortcut,
                  event.getIntegerValueField(.eventSourceUserData) != Self.postedShortcutTag,
                  shortcut.matchesKeyDown(event) else { return false }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                singleTabMode.toggle()
            }
            return true
        default:
            break
        }
        return false
    }

    private func handleTabScroll(_ event: CGEvent) -> Bool {
        guard !isRecordingShortcut else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        let phase = CGScrollPhase(rawValue: UInt32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventScrollPhase)))
        let swipeEnded = phase == .ended || phase == .cancelled
        let holdsBothShortcuts = modifierScrollEnabled
            && holdSingleTabShortcut?.isHeld(togetherWith: scrollShortcut, for: event) == true
        let useSingleTab = singleTabMode || holdsBothShortcuts || holdSingleTabShortcut?.isHeld(for: event) == true
        if continuous && !momentum && (useSingleTab || holdSingleTabShortcut != nil) {
            switch phase {
            case .began: gesture.observeSwipe(.began, now: now, reset: useSingleTab)
            case .changed: gesture.observeSwipe(.changed, now: now)
            case .ended, .cancelled: gesture.observeSwipe(.ended, now: now, reset: useSingleTab)
            case .mayBegin: break
            default: gesture.observeSwipe(.unphased, now: now, reset: useSingleTab)
            }
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier, let browser = Browser(rawValue: bundleID)
        else {
            gesture.resetAccumulation()
            gestureTarget = nil
            return false
        }

        guard isBrowserEnabled(browser) else {
            recordScrollResult("Disabled in TabScroll settings", browser: browser)
            gesture.resetAccumulation()
            gestureTarget = nil
            return false
        }

        guard CGPreflightPostEventAccess() else {
            status = AXIsProcessTrusted() ? .shortcutAccess : .accessibility
            stop()
            return false
        }

        let pid = app.processIdentifier
        let holdsShortcut = holdsBothShortcuts || (modifierScrollEnabled && scrollShortcut.isHeld(for: event))
        let continuesShortcut = momentum && gestureTarget?.pid == pid && gestureTarget?.modifierScroll == true
        let modifierScroll = modifierScrollEnabled && (holdsShortcut || continuesShortcut)

        let result: BrowserTabDetector.Result
        if modifierScroll {
            guard let window = detector.focusedWindow(for: pid, containing: event.location) else {
                gesture.resetAccumulation()
                gestureTarget = nil
                return false
            }
            if continuesShortcut, !holdsShortcut, let target = gestureTarget, !CFEqual(target.window, window) {
                gesture.resetAccumulation()
                gestureTarget = nil
                return false
            }
            result = .tabs(window)
        } else {
            result = detector.detect(browser: browser, pid: pid, point: event.location)
        }
        guard case let .tabs(window) = result else {
            if !momentum {
                if case .outside = result {
                    recordScrollResult("Outside tab area", browser: browser, detail: detector.lastDetectionDetail)
                } else {
                    recordScrollResult("Couldn’t read the tab area", browser: browser, detail: detector.lastDetectionDetail)
                }
            }
            gesture.resetAccumulation()
            gestureTarget = nil
            return false
        }

        if let target = gestureTarget,
           target.pid != pid || !CFEqual(target.window, window) || target.modifierScroll != modifierScroll {
            gesture.resetAccumulation()
        }
        gestureTarget = (pid, window, modifierScroll)

        let delta = event.getIntegerValueField(continuous ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)
        if pendingShortcut == nil, !(useSingleTab && continuous && swipeEnded),
           let direction = gesture.update(
            delta: delta, continuous: continuous, momentum: momentum,
            now: now,
            trackpadThreshold: 80 - sensitivity, reverse: reverseDirection,
            cooldown: cooldownMilliseconds / 1_000, singleTab: useSingleTab
           ) {
            scheduleShortcut(direction, browser: browser, pid: pid, window: window)
        }
        return true
    }

    private func scheduleShortcut(
        _ direction: ScrollGesture.Direction, browser: Browser, pid: pid_t, window: AXUIElement
    ) {
        pendingShortcut = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.pendingShortcut = nil
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let currentWindow = self.detector.focusedWindow(for: pid),
                  CFEqual(window, currentWindow),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            else {
                self.recordScrollResult("Tab area detected, but browser focus changed", browser: browser)
                return
            }

            let arrowKey: CGKeyCode = direction == .left ? 123 : 124
            guard CGPreflightPostEventAccess(),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: arrowKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: arrowKey, keyDown: false)
            else {
                self.recordScrollResult("Tab area detected, but couldn’t send the shortcut", browser: browser)
                return
            }

            down.flags = [.maskCommand, .maskAlternate]
            up.flags = down.flags
            down.setIntegerValueField(.eventSourceUserData, value: Self.postedShortcutTag)
            up.setIntegerValueField(.eventSourceUserData, value: Self.postedShortcutTag)
            // Deliver to the browser so open menu bar menus cannot receive the shortcut.
            down.postToPid(pid)
            up.postToPid(pid)
            self.recordScrollResult("Sent tab-switch shortcut", browser: browser)
        }
    }

    private func recordScrollResult(_ result: String, browser: Browser, detail: String = "") {
        let summary = "\(browser.name) · \(result)"
        let message = detail.isEmpty ? summary : "\(summary)\n\(detail)"
        if lastScrollResult != message { lastScrollResult = message }
    }
}
