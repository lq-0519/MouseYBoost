import AppKit
import ApplicationServices

/// Immutable worker configuration. Display rectangles use Quartz global
/// coordinates so vertically arranged and scaled displays share one space.
struct MouseConfiguration: Equatable {
    /// Requested gain of the physical vertical displacement; X is never rewritten.
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
        } else if !trusted || !CGPreflightPostEventAccess() {
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
final class MouseWorker {
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
    /// Marks this worker's replacement motion before any device lookup or
    /// fractional accounting, preventing synthetic input from feeding back.
    static let replacementMarker: Int64 = 0x4D59424F4F5354
    /// One reusable source posts motion without suppressing subsequent physical
    /// input. Creating a source per event would add unnecessary callback work.
    private let replacementSource: CGEventSource?
    /// Position of the preceding motion as observed in event-pipeline order.
    /// Unlike querying the live cursor on every callback, this remains stable
    /// when several input events are already waiting in the run-loop queue.
    private var precedingY: CGFloat?
    /// Latest requested output while replacement events are still in flight.
    /// New input accumulates here so an older queued coordinate cannot undo
    /// the gain of an earlier event.
    private var pendingOutputY: CGFloat?
    /// Counts replacements until they return through this tap. Tagged events
    /// acknowledge delivery without being scaled again.
    private var pendingReplacements = 0

    /// Creates a worker without starting a thread or touching input permissions.
    init(configuration: MouseConfiguration) {
        self.configuration = configuration
        desktopStrips = Self.makeDesktopStrips(configuration.displays)
        replacementSource = CGEventSource(stateID: .combinedSessionState)
        replacementSource?.localEventsSuppressionInterval = 0
        replacementSource?.userData = Self.replacementMarker
    }

    /// Installs the tap on a dedicated sleeping run loop. Cleanup stays on that
    /// same thread, including cancellation requested before CFRunLoopRun begins.
    func run() {
        lifecycleLock.lock()
        let shouldStart = !canceled
        lifecycleLock.unlock()
        guard shouldStart else { return }
        guard replacementSource != nil else {
            onStateChanged?(.failure("无法创建鼠标事件来源，增益未开启"))
            return
        }
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
                return worker.handle(type: type, event: event)
                    ? nil : Unmanaged.passUnretained(event)
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

    /// Filters device sources and handles tap lifecycle notifications. True means
    /// a replacement was posted, so the original must not also reach the cursor.
    /// Trackpad, unidentified, and already-tagged input always passes through.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout {
            timeoutCount += 1
            if timeoutCount <= 3, let tap {
                remainderY = 0
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                onStateChanged?(.failure("系统连续暂停了鼠标监听，请重新启用"))
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            return false
        }
        if type == .tapDisabledByUserInput {
            onStateChanged?(.failure("鼠标监听已被系统暂停，请检查权限后重新启用"))
            CFRunLoopStop(CFRunLoopGetCurrent())
            return false
        }
        timeoutCount = 0
        if event.getIntegerValueField(.eventSourceUserData) == Self.replacementMarker {
            precedingY = event.location.y
            if pendingReplacements > 0 { pendingReplacements -= 1 }
            if pendingReplacements == 0 { pendingOutputY = nil }
            return false
        }
        let sender = MYBEventSenderID(event)
        if sender != previousSender {
            previousSender = sender
            remainderY = 0
        }
        guard sender != 0 else {
            precedingY = event.location.y
            return false
        }
        let classification: Int
        if let cached = senders[sender] {
            classification = cached
        } else {
            classification = Int(MYBClassifySender(sender))
            if senders.count >= 64 { senders.removeAll(keepingCapacity: true) }
            senders[sender] = classification
        }
        guard classification == 1 else {
            precedingY = event.location.y
            pendingOutputY = nil
            return false
        }
        if !observedMouse {
            observedMouse = true
            onStateChanged?(.active)
        }
        return transformMotionEvent(event)
    }

    /// Replaces eligible motion through the normal event pipeline, preserving
    /// horizontal position, drag buttons, modifiers, pressure, and click state.
    /// CGWarpMouseCursorPosition suppresses subsequent physical cursor movement
    /// on this system and must never be used in the production input callback.
    ///
    /// Displacement between consecutive pipeline positions already includes
    /// macOS pointer acceleration. Only its Y component receives extra gain;
    /// neither raw HID displacement nor system acceleration settings are changed.
    /// The live cursor supplies the initial baseline only. Later baselines come
    /// from ordered events because the live cursor may lag during queued input.
    /// mouseEventDeltaY includes preceding synthetic adjustments on this system
    /// and therefore cannot be scaled directly.
    /// The caller alone authorizes the device; diagnostics reuse this exact core.
    func transformMotionEvent(_ event: CGEvent) -> Bool {
        let original = event.location
        guard original.x.isFinite, original.y.isFinite,
              let baseline = precedingY ?? CGEvent(source: nil)?.location.y,
              baseline.isFinite else {
            remainderY = 0
            return false
        }
        precedingY = original.y
        let acceleratedY = original.y - baseline
        let extra = acceleratedY * (configuration.gain - 1) + remainderY
        let roundedExtra = extra.rounded(.towardZero)
        remainderY = extra - roundedExtra
        let requestedY = (pendingOutputY ?? baseline) + acceleratedY + roundedExtra
        guard requestedY != original.y else { return false }
        let targetY = clampY(requestedY, atX: original.x, fromY: original.y)
        let applied = targetY - original.y
        guard applied != 0 else {
            remainderY = 0
            return false
        }
        let button: CGMouseButton = event.type == .rightMouseDragged ? .right
            : event.type == .otherMouseDragged ? .center : .left
        guard let replacementSource,
              let replacement = CGEvent(mouseEventSource: replacementSource,
                                         mouseType: event.type,
                                         mouseCursorPosition: CGPoint(x: original.x, y: targetY),
                                         mouseButton: button) else {
            remainderY = 0
            onStateChanged?(.failure("无法创建鼠标移动事件，增益已暂停"))
            CFRunLoopStop(CFRunLoopGetCurrent())
            return false
        }
        // A fresh mouse event excludes the original HID payload, which must not
        // be reintroduced as physical input. Copy the public motion/button state
        // explicitly; the new source owns only this tagged synthetic event.
        replacement.flags = event.flags
        replacement.setIntegerValueField(.mouseEventButtonNumber,
                                          value: event.getIntegerValueField(.mouseEventButtonNumber))
        replacement.setIntegerValueField(.mouseEventNumber,
                                          value: event.getIntegerValueField(.mouseEventNumber))
        replacement.setIntegerValueField(.mouseEventClickState,
                                          value: event.getIntegerValueField(.mouseEventClickState))
        replacement.setIntegerValueField(.mouseEventSubtype,
                                          value: event.getIntegerValueField(.mouseEventSubtype))
        replacement.setDoubleValueField(.mouseEventPressure,
                                         value: event.getDoubleValueField(.mouseEventPressure))
        replacement.setIntegerValueField(.mouseEventDeltaX,
                                          value: event.getIntegerValueField(.mouseEventDeltaX))
        replacement.setIntegerValueField(.eventSourceUserData, value: Self.replacementMarker)
        replacement.flags.insert(.maskNonCoalesced)
        replacement.location = CGPoint(x: original.x, y: targetY)
        replacement.setIntegerValueField(.mouseEventDeltaY, value: Int64(acceleratedY + applied))
        pendingOutputY = targetY
        pendingReplacements += 1
        replacement.post(tap: .cghidEventTap)
        return true
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
