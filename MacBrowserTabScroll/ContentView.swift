import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: TabSwitchingController
    @StateObject private var hoverHelp = HoverHelp()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            scrollingSettings
            browserSettings
            footer
        }
        .padding(13)
        .frame(width: 360, alignment: .leading)
        .overlayPreferenceValue(HelpAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let message = hoverHelp.visibleMessage, let anchor = anchors[message] {
                    let icon = geometry[anchor]
                    Text(message)
                        .font(.callout)
                        .padding(10)
                        .frame(width: 240, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .offset(x: min(max(8, icon.midX - 120), geometry.size.width - 248), y: icon.maxY + 5)
                        .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
        }
        .controlSize(.small)
        .toggleStyle(.switch)
        .background(TroubleshootingShortcut(onToggle: controller.toggleTroubleshooting))
        .onAppear(perform: controller.refreshLoginStatus)
        .onDisappear(perform: controller.cancelShortcutRecording)
        .onDisappear { hoverHelp.dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TabScroll")
                        .font(.title3.weight(.semibold))
                    Text(controller.status == .active ? "Active" : controller.enabled ? "Needs attention" : "Paused")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(controller.status == .active ? Color.accentColor : Color.secondary)
                }
                Spacer()
                Toggle("Tab Switching", isOn: Binding(
                    get: { controller.enabled },
                    set: controller.setEnabled
                ))
                .labelsHidden()
                .controlSize(.regular)
            }

            if controller.enabled && controller.status != .active {
                Text(controller.status.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if controller.status != .failed {
                        Button("Request Access", action: controller.requestPermission)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Try Again", action: controller.start)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var scrollingSettings: some View {
        settingsCard("Scrolling", icon: "slider.horizontal.3") {
            Slider(value: $controller.sensitivity, in: 10...70, step: 1) {
                Text("Trackpad sensitivity")
            } minimumValueLabel: {
                Text("Low")
            } maximumValueLabel: {
                Text("High")
            }

            HStack(spacing: 6) {
                Text("Cooldown")
                infoIcon("Minimum time between tab switches. Lower it to move through tabs faster, or raise it to avoid skipping tabs.")
                Spacer(minLength: 4)
                Button("−10") { adjustCooldown(by: -10) }
                    .disabled(controller.cooldownMilliseconds == 0)
                    .accessibilityLabel("Decrease cooldown by 10 milliseconds")
                TextField("Cooldown in milliseconds", value: cooldown, format: .number.precision(.fractionLength(1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 59)
                Text("ms")
                    .foregroundStyle(.secondary)
                Stepper("Adjust cooldown by 1 millisecond") {
                    adjustCooldown(by: 1)
                } onDecrement: {
                    adjustCooldown(by: -1)
                }
                .labelsHidden()
                Button("+10") { adjustCooldown(by: 10) }
                    .disabled(controller.cooldownMilliseconds == TabSwitchingController.maximumCooldownMilliseconds)
                    .accessibilityLabel("Increase cooldown by 10 milliseconds")
            }
            .buttonStyle(.bordered)

            Divider()
            Toggle("Reverse Direction", isOn: $controller.reverseDirection)
            HStack(spacing: 6) {
                Toggle(isOn: $controller.singleTabMode) {
                    HStack(spacing: 4) {
                        Text("Single Tab per Swipe")
                        infoIcon("Switch once per trackpad swipe for more precise navigation. Wheel switches are at least 400 ms apart. Use the keyboard menu to toggle the mode or use it only while held.")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                Menu {
                    Button("Toggle · \(controller.toggleSingleTabShortcut?.label ?? "Unassigned")") {
                        controller.beginShortcutRecording(.toggleSingleTab)
                    }
                    Button("Hold · \(controller.holdSingleTabShortcut?.label ?? "Unassigned")") {
                        controller.beginShortcutRecording(.holdSingleTab)
                    }
                    if controller.toggleSingleTabShortcut != nil || controller.holdSingleTabShortcut != nil {
                        Divider()
                        if controller.toggleSingleTabShortcut != nil {
                            Button("Clear Toggle Shortcut") { controller.clearSingleTabShortcut(.toggleSingleTab) }
                        }
                        if controller.holdSingleTabShortcut != nil {
                            Button("Clear Hold Shortcut") { controller.clearSingleTabShortcut(.holdSingleTab) }
                        }
                    }
                } label: {
                    Label("Hotkeys", systemImage: "keyboard")
                        .font(.caption.weight(.medium))
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .accessibilityLabel("Single Tab shortcuts")
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Toggle(isOn: $controller.modifierScrollEnabled) {
                    HStack(spacing: 4) {
                        Text("Scroll Anywhere")
                        infoIcon("Hold this shortcut to switch tabs over a webpage. Hold it together with the Single Tab hold shortcut to switch one tab per swipe anywhere in the browser.")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                Button {
                    controller.beginShortcutRecording(.scrollAnywhere)
                } label: {
                    Label("Hotkey: \(controller.scrollShortcut.label)", systemImage: "keyboard")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 123)
                }
                .fixedSize(horizontal: true, vertical: false)
                .buttonStyle(.bordered)
                .help("Change Scroll Anywhere shortcut")
                .accessibilityLabel("Change Scroll Anywhere shortcut, currently \(controller.scrollShortcut.label)")
                Spacer(minLength: 0)
            }

            if controller.isRecordingShortcut {
                shortcutRecording
            }
        }
    }

    private var shortcutRecording: some View {
        VStack(alignment: .leading, spacing: 5) {
            ShortcutRecorder(onCapture: controller.captureShortcut)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
            Text(controller.recordedShortcut?.label ?? recordingHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Save Shortcut", action: controller.saveRecordedShortcut)
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canSaveShortcut)
                Button("Cancel", action: controller.cancelShortcutRecording)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var recordingHint: String {
        switch controller.recordingAction {
        case .toggleSingleTab: "Press a key to toggle Single Tab mode."
        case .holdSingleTab: "Press the keys to hold for Single Tab mode."
        case .scrollAnywhere, nil: "Press the keys to hold while scrolling anywhere."
        }
    }

    private var browserSettings: some View {
        settingsCard("Browsers", icon: "globe") {
            HStack(spacing: 0) {
                ForEach(Browser.allCases, id: \.self) { browser in
                    Toggle(browser.name, isOn: Binding(
                        get: { controller.isBrowserEnabled(browser) },
                        set: { controller.setBrowserEnabled($0, for: browser) }
                    ))
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: true, vertical: false)
                    if browser != Browser.allCases.last {
                        Spacer(minLength: 6)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { controller.loginStatus == .enabled || controller.loginStatus == .requiresApproval },
                    set: controller.setLaunchAtLogin
                ))
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Quit TabScroll")
            }
            if controller.loginStatus == .requiresApproval {
                Button("Approve in System Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if let loginError = controller.loginError {
                Text(loginError)
                    .foregroundStyle(.secondary)
            }

            if controller.showsTroubleshooting {
                Divider()
                Text(controller.lastScrollResult)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(.horizontal, 2)
    }

    private func settingsCard<Content: View>(
        _ title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }

    private func infoIcon(_ explanation: String) -> some View {
        Image(systemName: "info.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 19, height: 19)
            .contentShape(Rectangle())
            .anchorPreference(key: HelpAnchorKey.self, value: .bounds) { [explanation: $0] }
            .onHover { hovering in
                if hovering {
                    hoverHelp.show(explanation)
                } else {
                    hoverHelp.dismiss(explanation)
                }
            }
            .accessibilityLabel("About this setting")
            .accessibilityHint(explanation)
    }

    private var cooldown: Binding<Double> {
        Binding(
            get: { controller.cooldownMilliseconds },
            set: controller.setCooldownMilliseconds
        )
    }

    private func adjustCooldown(by amount: Double) {
        controller.setCooldownMilliseconds(controller.cooldownMilliseconds + amount)
    }
}

private struct HelpAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private final class HoverHelp: ObservableObject {
    @Published private(set) var visibleMessage: String?
    private var hoveredMessage: String?
    private var pending: Task<Void, Never>?

    func show(_ message: String) {
        dismiss()
        hoveredMessage = message
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.visibleMessage = message
        }
    }

    func dismiss(_ message: String? = nil) {
        guard message == nil || message == hoveredMessage else { return }
        pending?.cancel()
        pending = nil
        hoveredMessage = nil
        visibleMessage = nil
    }
}

private struct TroubleshootingShortcut: NSViewRepresentable {
    let onToggle: () -> Bool

    func makeNSView(context: Context) -> ShortcutView {
        let view = ShortcutView()
        view.onToggle = onToggle
        return view
    }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.onToggle = onToggle
    }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ShortcutView: NSView {
        var onToggle: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isVisible, event.window === window,
                      !event.isARepeat, event.charactersIgnoringModifiers?.lowercased() == "d",
                      event.modifierFlags.intersection([.command, .option, .shift, .control]) == [.command, .option, .shift],
                      self.onToggle?() == true
                else { return event }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
