import Foundation

struct ScrollGesture {
    enum Direction {
        case left, right
    }

    enum SwipePhase {
        case began, changed, ended, unphased
    }

    private var accumulated: Double = 0
    private var lastEventTime: TimeInterval?
    private var lastSwitchTime: TimeInterval?
    private var lastDirection: Direction?
    private var switchedThisSwipe = false
    private var lastSwipeEvent: TimeInterval?

    mutating func resetAccumulation() {
        accumulated = 0
        lastEventTime = nil
        lastDirection = nil
    }

    mutating func observeSwipe(_ phase: SwipePhase, now: TimeInterval, reset: Bool = true) {
        switch phase {
        case .began, .ended:
            switchedThisSwipe = false
            if reset { resetAccumulation() }
        case .unphased:
            if let lastSwipeEvent, now - lastSwipeEvent >= 0.4 {
                switchedThisSwipe = false
                if reset { resetAccumulation() }
            }
        case .changed:
            break
        }
        lastSwipeEvent = now
    }

    mutating func update(
        delta: Int64, continuous: Bool, momentum: Bool, now: TimeInterval,
        trackpadThreshold: Double = 40, reverse: Bool = true,
        cooldown: TimeInterval = 0.02, singleTab: Bool = false
    ) -> Direction? {
        guard !momentum, delta != 0 else { return nil }
        if singleTab && continuous && switchedThisSwipe { return nil }

        let direction: Direction = (delta < 0) == reverse ? .left : .right
        if let lastEventTime, now - lastEventTime > 0.3 || direction != lastDirection {
            resetAccumulation()
        }
        lastEventTime = now
        lastDirection = direction
        accumulated += abs(Double(delta))

        let threshold: Double = continuous ? trackpadThreshold : 1
        guard accumulated >= threshold else { return nil }
        let minimumDelay = singleTab && !continuous ? max(cooldown, 0.4) : cooldown
        if let lastSwitchTime, now - lastSwitchTime < minimumDelay { return nil }

        accumulated = 0
        lastSwitchTime = now
        if singleTab && continuous { switchedThisSwipe = true }
        return direction
    }
}
