import ApplicationServices
import Foundation

enum Browser: String, CaseIterable {
    case brave = "com.brave.Browser"
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"
    case firefox = "org.mozilla.firefox"

    var name: String {
        switch self {
        case .brave: "Brave"
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .firefox: "Firefox"
        }
    }
}

final class BrowserTabDetector {
    enum Result {
        case tabs(AXUIElement)
        case outside, unavailable
    }

    private struct Window {
        let element: AXUIElement
        let pid: pid_t
        let frame: CGRect

        func matches(_ other: Self) -> Bool {
            pid == other.pid && frame == other.frame && CFEqual(element, other.element)
        }
    }

    private struct Node {
        let element: AXUIElement
        let role: String
    }

    private static let webAreaRole = "AXWebArea"

    private let system = AXUIElementCreateSystemWide()
    private(set) var lastDetectionDetail = ""
    private var windowTabGroupsChecked = 0
    private var browserTabGroupFound = false
    private var firefoxAccessibilityRequest: (pid: pid_t, time: TimeInterval)?
    private var deadline: TimeInterval = 0
    private var groupCache: (window: Window, point: CGPoint, time: TimeInterval, result: Bool)?
    private var edgeCache: (window: Window, time: TimeInterval, frame: CGRect?)?

    init() {
        _ = AXUIElementSetMessagingTimeout(system, 0.04)
    }

    func detect(browser: Browser, pid: pid_t, point: CGPoint) -> Result {
        lastDetectionDetail = ""
        windowTabGroupsChecked = 0
        browserTabGroupFound = false
        let now = ProcessInfo.processInfo.systemUptime
        deadline = now + 0.10

        if browser == .firefox, firefoxAccessibilityRequest?.pid != pid {
            requestFirefoxAccessibility(for: pid, now: now)
        }

        guard let element = focusedWindow(for: pid), let frame = bounds(of: element) else {
            lastDetectionDetail = "Focused window or its bounds unavailable"
            return .unavailable
        }
        guard frame.contains(point) else {
            lastDetectionDetail = "Scroll point is outside the focused window"
            return .outside
        }

        let window = Window(element: element, pid: pid, frame: frame)
        guard var nodes = path(at: point, in: window, allowWindowAttribute: browser == .edge)
        else {
            lastDetectionDetail = hasTime ? "Couldn’t trace the element to the focused window" : "Accessibility lookup timed out"
            return .unavailable
        }
        if browser == .firefox, nodes.isEmpty {
            if let request = firefoxAccessibilityRequest, now - request.time >= 1 {
                requestFirefoxAccessibility(for: pid, now: now)
            }
            let application = AXUIElementCreateApplication(pid)
            if let appNodes = path(at: point, in: window, hitTestRoot: application) {
                nodes = appNodes
            }
        }

        let isInTabs: Bool
        switch browser {
        case .brave:
            isInTabs = groupTabs(at: point, nodes: nodes, window: window, now: now)
        case .chrome:
            isInTabs = chromeTabs(at: point, nodes: nodes, window: window, now: now)
        case .edge:
            guard !nodes.contains(where: { $0.role == Self.webAreaRole }) else { return .outside }
            if nodes.contains(where: isEdgeTabBar)
                || windowTabGroupContains(point, in: window, matching: isEdgeTabBar) {
                return hasTime ? .tabs(element) : .unavailable
            }
            guard let page = edgeWebpage(in: window, now: now) else {
                let reason = hasTime ? "No Tab bar match or webpage boundary" : "Webpage lookup timed out"
                lastDetectionDetail = failureDetail(reason, nodes: nodes)
                return .unavailable
            }
            isInTabs = edgeTabs(at: point, frame: frame, page: page)
        case .firefox:
            isInTabs = firefoxTabs(at: point, nodes: nodes, window: window, now: now)
        }

        guard hasTime else {
            lastDetectionDetail = failureDetail("Accessibility lookup timed out", nodes: nodes)
            return .unavailable
        }
        if !isInTabs, browser == .firefox || browser == .edge {
            lastDetectionDetail = failureDetail("No matching tab region", nodes: nodes)
            if browser == .firefox {
                lastDetectionDetail += "\nWindow tab groups checked: \(windowTabGroupsChecked)"
                if browserTabGroupFound {
                    lastDetectionDetail += "\nBrowser tab group found, but its bounds did not match"
                }
            }
        }
        return isInTabs ? .tabs(element) : .outside
    }

    private func requestFirefoxAccessibility(for pid: pid_t, now: TimeInterval) {
        // Firefox initializes its accessibility tree when a client reads the app role.
        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, 0.04)
        _ = Self.attribute(kAXRoleAttribute, of: application)
        firefoxAccessibilityRequest = (pid, now)
    }

    private func failureDetail(_ reason: String, nodes: [Node]) -> String {
        let roles = nodes.suffix(8).map(\.role).joined(separator: " → ")
        return "\(reason)\n\(roles.isEmpty ? "Hit the window itself" : roles)"
    }

    func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.04)
        return Self.element(Self.attribute(kAXFocusedWindowAttribute, of: app))
    }

    func focusedWindow(for pid: pid_t, containing point: CGPoint) -> AXUIElement? {
        deadline = ProcessInfo.processInfo.systemUptime + 0.10
        guard let window = focusedWindow(for: pid), let frame = bounds(of: window),
              hasTime, frame.contains(point) else { return nil }
        return window
    }

    private func groupTabs(at point: CGPoint, nodes: [Node], window: Window, now: TimeInterval) -> Bool {
        if let cache = groupCache, cache.window.matches(window), now - cache.time < 0.15,
           abs(point.x - cache.point.x) < 2, abs(point.y - cache.point.y) < 2 {
            return cache.result
        }

        let frame = window.frame
        let matches = nodes.contains { node in
            guard node.role == kAXGroupRole, let rect = bounds(of: node.element),
                  rect.contains(point) else { return false }

            let vertical = abs(rect.minX - frame.minX) < 8
                && (30...450).contains(rect.width) && rect.width < frame.width * 0.7
                && rect.height >= frame.height * 0.5
                && (frame.minY + 20...frame.minY + 260).contains(rect.minY)
            let horizontal = (28...55).contains(rect.height) && rect.width >= frame.width * 0.35
                && (frame.minY - 3...frame.minY + 30).contains(rect.minY)
                && rect.minX >= frame.minX + 20 && rect.maxX <= frame.maxX + 3
            return vertical || horizontal
        }

        if hasTime { groupCache = (window, point, now, matches) }
        return matches
    }

    private func chromeTabs(at point: CGPoint, nodes: [Node], window: Window, now: TimeInterval) -> Bool {
        if chromeTabGroup(at: point, nodes: nodes) { return true }

        let frame = window.frame
        guard point.y < frame.minY + 55 else { return false }
        let probe = CGPoint(x: frame.minX + 20, y: frame.minY + min(180, frame.height * 0.35))
        if let probeNodes = path(at: probe, in: window), chromeTabGroup(at: probe, nodes: probeNodes) {
            return false
        }
        return groupTabs(at: point, nodes: nodes, window: window, now: now)
    }

    private func chromeTabGroup(at point: CGPoint, nodes: [Node]) -> Bool {
        for node in nodes where node.role == kAXTabGroupRole {
            if let rect = bounds(of: node.element) { return rect.contains(point) }
        }
        return false
    }

    private func isEdgeTabBar(_ node: Node) -> Bool {
        guard hasTime, node.role == kAXTabGroupRole else { return false }
        return Self.attribute(kAXDescriptionAttribute, of: node.element) as? String == "Tab bar"
            || (hasTime && Self.attribute(kAXTitleAttribute, of: node.element) as? String == "Tab bar")
    }

    private func windowTabGroupContains(
        _ point: CGPoint, in window: Window, matching isTabGroup: (Node) -> Bool
    ) -> Bool {
        // Some hit tests return a wrapper or the window itself. Search the
        // focused window's chrome for a positively identified tab group.
        let limit = 96
        var queue = [window.element]
        var index = 0
        while hasTime && index < queue.count {
            let element = queue[index]
            index += 1
            guard let role = Self.attribute(kAXRoleAttribute, of: element) as? String,
                  role != Self.webAreaRole, role != kAXMenuRole else { continue }

            if role == kAXTabGroupRole {
                windowTabGroupsChecked += 1
                if isTabGroup(Node(element: element, role: role)) {
                    browserTabGroupFound = true
                    if let rect = bounds(of: element), rect.contains(point) { return true }
                }
            }

            if hasTime, queue.count < limit,
               let children = Self.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(limit - queue.count))
            }
        }
        return false
    }

    private func edgeTabs(at point: CGPoint, frame: CGRect, page: CGRect) -> Bool {
        let leftGap = page.minX - frame.minX
        if leftGap >= 32 && leftGap < frame.width - 160 {
            return point.x < page.minX && point.y >= max(frame.minY + 60, page.minY - 12)
        }

        return point.x >= frame.minX + 75 && point.x < frame.maxX - 20
            && point.y < min(frame.minY + 45, page.minY - 20)
    }

    private func edgeWebpage(in window: Window, now: TimeInterval) -> CGRect? {
        if let cache = edgeCache, cache.window.matches(window), now - cache.time < 0.15 {
            return cache.frame
        }

        let frame = window.frame
        let probe = CGPoint(
            x: frame.maxX - min(30, frame.width * 0.1),
            y: frame.minY + min(250, frame.height * 0.5)
        )
        // The original right-side probe can land in Edge's tools sidebar.
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let page = edgePageBounds(at: probe, in: window) ?? edgePageBounds(at: center, in: window)
        if hasTime { edgeCache = (window, now, page) }
        return page
    }

    private func edgePageBounds(at point: CGPoint, in window: Window) -> CGRect? {
        guard let nodes = path(at: point, in: window, allowWindowAttribute: true) else { return nil }
        let frame = window.frame
        for node in nodes where node.role == Self.webAreaRole {
            if let rect = bounds(of: node.element), rect.contains(point),
               rect.width > max(150, frame.width * 0.12), rect.height > frame.height * 0.35 {
                return rect
            }
        }
        return nil
    }

    private func firefoxTabs(at point: CGPoint, nodes: [Node], window: Window, now: TimeInterval) -> Bool {
        guard !nodes.contains(where: { $0.role == Self.webAreaRole }) else { return false }
        let frame = window.frame
        if nodes.contains(where: isFirefoxBrowserTabList) { return true }
        if firefoxTabGroup(at: point, nodes: nodes, frame: frame) { return true }

        // Firefox can expose its own tab list without a usable AXTabGroup frame.
        // Match the browser UI's explicit identifier after excluding web content.
        if nodes.contains(where: { node in
            hasTime && Self.attribute("AXDOMIdentifier", of: node.element) as? String == "tabbrowser-tabs"
        }) {
            return true
        }
        if windowTabGroupContains(point, in: window, matching: isFirefoxBrowserTabList) {
            return true
        }
        guard point.y >= frame.minY + 55 else { return false }

        let probe = CGPoint(x: frame.minX + min(200, frame.width * 0.5), y: frame.minY + 20)
        if let probeNodes = path(at: probe, in: window),
           firefoxTabGroup(at: probe, nodes: probeNodes, frame: frame) {
            return false
        }
        return groupTabs(at: point, nodes: nodes, window: window, now: now)
    }

    private func isFirefoxBrowserTabList(_ node: Node) -> Bool {
        guard hasTime, node.role == kAXTabGroupRole else { return false }
        if Self.attribute("AXDOMIdentifier", of: node.element) as? String == "tabbrowser-tabs" {
            return true
        }
        guard hasTime,
              let children = Self.attribute(kAXChildrenAttribute, of: node.element) as? [AXUIElement]
        else { return false }

        // Firefox's sidebar tools also use AXTabGroup. The browser tab group
        // has its own New Tab button, even when its bounds fail the layout checks.
        for child in children.reversed().prefix(8) {
            guard hasTime else { return false }
            guard Self.attribute(kAXRoleAttribute, of: child) as? String == kAXButtonRole else { continue }
            if hasTime && Self.attribute("AXDOMIdentifier", of: child) as? String == "tabs-newtab-button" {
                return true
            }
            if hasTime && Self.attribute(kAXTitleAttribute, of: child) as? String == "New Tab" {
                return true
            }
            if hasTime && Self.attribute(kAXDescriptionAttribute, of: child) as? String == "New Tab" {
                return true
            }
        }
        return false
    }

    private func firefoxTabGroup(at point: CGPoint, nodes: [Node], frame: CGRect) -> Bool {
        guard !nodes.contains(where: { $0.role == Self.webAreaRole }) else { return false }

        return nodes.contains { node in
            guard node.role == kAXTabGroupRole, let rect = bounds(of: node.element),
                  rect.contains(point) else { return false }

            let vertical = abs(rect.minX - frame.minX) < 12 && rect.height >= frame.height * 0.45
                && rect.width >= 30 && rect.width < frame.width - 100
            let horizontal = (28...70).contains(rect.height)
                && (frame.minY - 5...frame.minY + 25).contains(rect.minY) && rect.width >= 100
            return vertical || horizontal
        }
    }

    private var hasTime: Bool {
        ProcessInfo.processInfo.systemUptime < deadline
    }

    private func path(
        at point: CGPoint, in window: Window, allowWindowAttribute: Bool = false,
        hitTestRoot: AXUIElement? = nil
    ) -> [Node]? {
        guard hasTime else { return nil }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(hitTestRoot ?? system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == window.pid else { return nil }

        // Walk from the hit element to the focused window, then inspect outer nodes first as in Lua.
        var nodes: [Node] = []
        var element = hit
        for _ in 0..<64 {
            if CFEqual(element, window.element) { return Array(nodes.reversed()) }
            guard hasTime, let role = Self.attribute(kAXRoleAttribute, of: element) as? String,
                  role != kAXWindowRole else { return nil }
            nodes.append(Node(element: element, role: role))
            guard hasTime, let parent = Self.element(Self.attribute(kAXParentAttribute, of: element)) else {
                if allowWindowAttribute, hasTime,
                   let owner = Self.element(Self.attribute(kAXWindowAttribute, of: hit)),
                   CFEqual(owner, window.element) {
                    return Array(nodes.reversed())
                }
                return nil
            }
            element = parent
        }
        return nil
    }

    private func bounds(of element: AXUIElement) -> CGRect? {
        guard hasTime, let position = Self.value(kAXPositionAttribute, of: element),
              hasTime, let size = Self.value(kAXSizeAttribute, of: element) else { return nil }

        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement?
    }

    private static func value(_ name: String, of element: AXUIElement) -> AXValue? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return value as! AXValue?
    }
}
