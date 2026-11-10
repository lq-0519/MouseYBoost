import AppKit
import ApplicationServices

/// Immutable worker configuration. Display rectangles use Quartz global
/// coordinates so vertically arranged and scaled displays share one space.
struct MouseConfiguration: Equatable {
    /// Requested gain of the vertical event delta; X is never rewritten.
    let gain: Double
    /// Cached desktop geometry, refreshed only when the display layout changes.
    let displays: [CGRect]
}

/// Runtime state is published only on transitions, never on every mouse event.
enum EngineState: Equatable {
    /// User has turned off processing.
    case disabled
    /// Gain is one, so the worker is not needed.
    case unchanged
    /// Accessibility permission is required before a modifying tap can run.
    case permissionRequired
    /// Machine is asleep; the tap has been removed.
    case sleeping
    /// Tap is ready and has not yet observed an identified Logitech mouse.
    case waitingForMouse
    /// At least one identified external Logitech motion event was received.
    case active
    /// A recoverable start or runtime error is shown in the settings window.
    case failure(String)

    /// Short human-readable state for the menu and settings window.
    var text: String {
        switch self {
        case .disabled: return "已关闭 · 没有鼠标事件监听"
        case .unchanged: return "1 倍原速 · 没有鼠标事件监听"
        case .permissionRequired: return "需要开启辅助功能权限"
        case .sleeping: return "电脑休眠中 · 已暂停"
        case .waitingForMouse: return "监听已开启 · 等待罗技鼠标移动"
        case .active: return "正在为罗技外接鼠标提供纵向增益"
        case let .failure(message): return message
        }
    }
}

/// Owns a single worker and serializes replacement on one sleeping run loop.
/// All public methods and status delivery execute on the application's main thread.
final class MouseEngine {
    /// Notification callback is invoked only when visible runtime state changes.
    var onStateChanged: ((EngineState) -> Void)?
    /// Most recent state drives UI without polling or per-event counters.
    private(set) var state: EngineState = .disabled
    /// One serial queue prevents old and new taps from processing concurrently.
    private let workerQueue = DispatchQueue(label: "com.local.MouseYBoost.events",
                                            qos: .userInteractive)
    /// Current worker is canceled immediately when settings change.
    private var worker: MouseWorker?
    /// Snapshot avoids restarting a healthy tap for unrelated app activation.
    private var configuration: MouseConfiguration?

    /// Applies settings and permission status; starting at one or while disabled
    /// requires no event tap, background timer, or device observer.
    func apply(enabled: Bool, gain: Double, trusted: Bool, asleep: Bool,
               displays: [CGRect]) {
        let inactive: EngineState?
        if !enabled {
            inactive = .disabled
        } else if gain == 1 {
            inactive = .unchanged
        } else if asleep {
            inactive = .sleeping
        } else if !trusted {
            inactive = .permissionRequired
        } else {
            inactive = nil
        }
        if let inactive {
            stop()
            publish(inactive)
            return
        }
        guard MYBDeviceBridgeAvailable() else {
            stop()
            publish(.failure("当前系统无法识别鼠标来源，增益未开启"))
            return
        }
        let next = MouseConfiguration(gain: gain, displays: displays)
        guard configuration != next || worker == nil else { return }
        stop()
        configuration = next
        let nextWorker = MouseWorker(configuration: next)
        worker = nextWorker
        nextWorker.onStateChanged = { [weak self, weak nextWorker] state in
            DispatchQueue.main.async { [weak self, weak nextWorker] in
                guard let self, let nextWorker, self.worker === nextWorker else { return }
                if case .failure = state {
                    self.stop()
                }
                self.publish(state)
            }
        }
        workerQueue.async { nextWorker.run() }
    }

    /// Cancels the worker and clears its snapshot. The queue drains teardown
    /// before starting a replacement, without blocking the settings UI.
    func stop() {
        worker?.stop()
        worker = nil
        configuration = nil
    }

    /// Deduplicates visible state changes to keep main-thread work event driven.
    private func publish(_ next: EngineState) {
        guard state != next else { return }
        state = next
        onStateChanged?(next)
    }
}

/// Precomputed desktop strip. Its half-open X interval shares the same merged
/// vertical display coverage, so cursor motion needs no geometry allocation.
private struct DesktopStrip {
    /// Horizontal interval bounded by two display edges.
    let horizontal: Range<CGFloat>
    /// Connected vertical intervals in Quartz global coordinates.
    let vertical: [ClosedRange<CGFloat>]
}

/// Event-thread implementation. No preferences, UI, timers, or disk writes occur
/// in the callback. Only cancellation/run-loop publication uses a mutex.
private final class MouseWorker {
    /// Immutable settings for the full lifetime of this worker.
    private let configuration: MouseConfiguration
    /// Sparse status callback is dispatched to the main thread by MouseEngine.
    var onStateChanged: ((EngineState) -> Void)?
    /// Protects cancellation and run-loop publication across the main/event threads.
    private let lifecycleLock = NSLock()
    /// A worker canceled before it starts must never install an event tap.
    private var canceled = false
    /// Published run loop allows cancellation without a periodic wake-up.
    private var runLoop: CFRunLoop?
    /// The tap port belongs exclusively to the worker thread.
    private var tap: CFMachPort?
    /// Bounded registry classification cache avoids IOKit calls on recurring input.
    private var senders: [UInt64: Int] = [:]
    /// Fractional extra displacement prevents small gains from rounding to zero.
    private var remainderY = 0.0
    /// Sender changes reset rounding state between independent physical devices.
    private var previousSender: UInt64 = 0
    /// Tracks first matching input so it produces only one UI notification.
    private var observedMouse = false
    /// Consecutive timeout notifications allow bounded immediate tap recovery.
    private var timeoutCount = 0
    /// Desktop strips are precomputed once, outside the input callback.
    private let desktopStrips: [DesktopStrip]
    /// Most movement remains in this strip, requiring only a containment check.
    private var cachedStripIndex: Int?

    /// Creates a worker without starting a thread or touching input permissions.
    init(configuration: MouseConfiguration) {
        self.configuration = configuration
        desktopStrips = Self.makeDesktopStrips(configuration.displays)
    }

    /// Installs the tap on a dedicated sleeping run loop. Cleanup stays on that
    /// same thread, including cancellation requested before CFRunLoopRun begins.
    func run() {
        lifecycleLock.lock()
        let shouldStart = !canceled
        lifecycleLock.unlock()
        guard shouldStart else { return }
        let eventTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let worker = Unmanaged<MouseWorker>.fromOpaque(context).takeUnretainedValue()
                worker.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            onStateChanged?(.failure("鼠标监听创建失败，请检查辅助功能权限后重新启用"))
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            onStateChanged?(.failure("无法创建鼠标事件运行循环"))
            return
        }
        tap = port
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, source, .defaultMode)
        lifecycleLock.lock()
        let alreadyCanceled = canceled
        runLoop = alreadyCanceled ? nil : loop
        lifecycleLock.unlock()
        if !alreadyCanceled {
            CGEvent.tapEnable(tap: port, enable: true)
            onStateChanged?(.waitingForMouse)
            CFRunLoopRun()
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        CFRunLoopRemoveSource(loop, source, .defaultMode)
        lifecycleLock.lock()
        runLoop = nil
        lifecycleLock.unlock()
        tap = nil
    }

    /// Queues cancellation on the worker's own loop. PerformBlock also works
    /// when stop races with the interval immediately before CFRunLoopRun.
    func stop() {
        lifecycleLock.lock()
        canceled = true
        let loop = runLoop
        lifecycleLock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
    }

    /// Adjusts only identified physical Logitech motion. The existing event is
    /// forwarded with its buttons/modifiers/X untouched; cursor warping creates
    /// no synthetic events and therefore cannot feed back into this callback.
    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout {
            timeoutCount += 1
            if timeoutCount <= 3, let tap {
                remainderY = 0
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                onStateChanged?(.failure("系统连续暂停了鼠标监听，请重新启用"))
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            return
        }
        if type == .tapDisabledByUserInput {
            onStateChanged?(.failure("鼠标监听已被系统暂停，请检查权限后重新启用"))
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }
        timeoutCount = 0
        let sender = MYBEventSenderID(event)
        if sender != previousSender {
            previousSender = sender
            remainderY = 0
        }
        guard sender != 0 else { return }
        let classification: Int
        if let cached = senders[sender] {
            classification = cached
        } else {
            classification = Int(MYBClassifySender(sender))
            if senders.count >= 64 { senders.removeAll(keepingCapacity: true) }
            senders[sender] = classification
        }
        guard classification == 1 else { return }
        if !observedMouse {
            observedMouse = true
            onStateChanged?(.active)
        }
        let deltaY = event.getIntegerValueField(.mouseEventDeltaY)
        guard deltaY != 0 else { return }
        let extra = Double(deltaY) * (configuration.gain - 1) + remainderY
        let roundedExtra = extra.rounded(.towardZero)
        remainderY = extra - roundedExtra
        guard roundedExtra != 0 else { return }
        let original = event.location
        guard original.x.isFinite, original.y.isFinite else {
            remainderY = 0
            return
        }
        let targetY = clampY(original.y + roundedExtra, atX: original.x, fromY: original.y)
        let applied = targetY - original.y
        guard applied != 0 else {
            remainderY = 0
            return
        }
        let target = CGPoint(x: original.x, y: targetY)
        guard CGWarpMouseCursorPosition(target) == .success else {
            remainderY = 0
            onStateChanged?(.failure("系统拒绝调整指针位置，请检查辅助功能权限"))
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }
        event.location = target
        event.setIntegerValueField(.mouseEventDeltaY, value: deltaY + Int64(applied))
    }

    /// Clamps to the connected desktop interval containing the input event.
    /// Only Y changes; disconnected display gaps cannot pull X into a new screen.
    private func clampY(_ requested: CGFloat, atX x: CGFloat, fromY origin: CGFloat) -> CGFloat {
        if cachedStripIndex == nil
            || !desktopStrips[cachedStripIndex!].horizontal.contains(x) {
            cachedStripIndex = desktopStrips.firstIndex { $0.horizontal.contains(x) }
        }
        guard let index = cachedStripIndex,
              let interval = desktopStrips[index].vertical.first(where: { $0.contains(origin) }) else {
            return origin
        }
        return min(interval.upperBound, max(interval.lowerBound, requested))
    }

    /// Partitions display geometry at each X edge, merging touching Y ranges
    /// once during worker creation. No sorting or temporary arrays are needed
    /// while the user moves the mouse.
    private static func makeDesktopStrips(_ displays: [CGRect]) -> [DesktopStrip] {
        let valid = displays.filter { $0.width >= 1 && $0.height >= 1 }
        let edges = Array(Set(valid.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard edges.count >= 2 else { return [] }
        var strips: [DesktopStrip] = []
        for index in 0..<(edges.count - 1) {
            let left = edges[index]
            let right = edges[index + 1]
            let ranges = valid.filter { $0.minX <= left && $0.maxX >= right }
                .map { $0.minY...($0.maxY - 1) }
                .sorted { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<CGFloat>] = []
            for range in ranges {
                if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            if !merged.isEmpty {
                strips.append(DesktopStrip(horizontal: left..<right, vertical: merged))
            }
        }
        return strips
    }
}
