import AppKit
import ApplicationServices

/// Immutable worker configuration. Display rectangles use Quartz global
/// coordinates so vertically arranged and scaled displays share one space.
struct MouseConfiguration: Equatable {
    /// Enables only identified external Logitech pointer events. Trackpad
    /// eligibility is controlled independently by trackpadEnabled.
    let mouseEnabled: Bool
    /// Enables identified trackpad pointer events independently of the mouse.
    let trackpadEnabled: Bool
    /// Extra vertical gain for external Logitech input only; one is pass-through.
    let mouseGain: Double
    /// Extra vertical gain for trackpad input only, independent of mouseGain.
    let trackpadGain: Double
    /// Cached desktop geometry, refreshed only when the display layout changes.
    let displays: [CGRect]

    /// Indicates whether mouse input needs the worker. A checked switch at one
    /// remains a user preference but does not require modifying mouse events.
    var boostsMouse: Bool { mouseEnabled && mouseGain != 1 }

    /// Indicates whether trackpad input needs gain, including while the mouse
    /// switch is off or its independent multiplier is set to one.
    var boostsTrackpad: Bool { trackpadEnabled && trackpadGain != 1 }

    /// Names only enabled categories with gain above one for the waiting state;
    /// devices set to their system speed are never reported as awaiting gain.
    var deviceDescription: String {
        if boostsMouse && boostsTrackpad { return "罗技鼠标和触控板" }
        return boostsMouse ? "罗技鼠标" : "触控板"
    }

    /// Selects the saved multiplier only after the sender has been classified.
    /// Nil leaves disabled, unit-gain, unsupported, and unknown input untouched.
    func gain(for device: MYBDeviceKind) -> Double? {
        switch device {
        case .logitechMouse where boostsMouse: return mouseGain
        case .trackpad where boostsTrackpad: return trackpadGain
        default: return nil
        }
    }
}

/// Runtime state is published only on transitions, never on every mouse event.
enum EngineState: Equatable {
    /// User has turned off both independent device switches.
    case disabled
    /// All enabled devices use unit gain, so the worker is not needed.
    case unchanged
    /// Accessibility permission is required before a modifying tap can run.
    case permissionRequired
    /// Machine is asleep; the tap has been removed.
    case sleeping
    /// Tap is ready but has not yet observed input from the named enabled devices.
    case waitingForInput(String)
    /// Identified input was received from the named enabled device categories.
    /// Each newly observed category updates this state once per worker lifetime.
    case active(String)
    /// A recoverable start or runtime error is shown in the settings window.
    case failure(String)

    /// Short human-readable state for the menu and settings window.
    var text: String {
        switch self {
        case .disabled: return "鼠标和触控板增益均已关闭 · 没有事件监听"
        case .unchanged: return "已启用设备均为 1 倍原速 · 没有事件监听"
        case .permissionRequired: return "需要开启辅助功能权限"
        case .sleeping: return "电脑休眠中 · 已暂停"
        case let .waitingForInput(devices): return "监听已开启 · 等待\(devices)移动"
        case let .active(devices): return "纵向增益已生效 · \(devices)"
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

    /// Applies independent switches and multipliers. The worker runs only when
    /// at least one enabled device needs gain; each other category passes through.
    func apply(mouseEnabled: Bool, trackpadEnabled: Bool,
               mouseGain: Double, trackpadGain: Double,
               trusted: Bool, asleep: Bool,
               displays: [CGRect]) {
        let next = MouseConfiguration(mouseEnabled: mouseEnabled,
                                      trackpadEnabled: trackpadEnabled,
                                      mouseGain: mouseGain, trackpadGain: trackpadGain,
                                      displays: displays)
        let inactive: EngineState?
        if !mouseEnabled && !trackpadEnabled {
            inactive = .disabled
        } else if !next.boostsMouse && !next.boostsTrackpad {
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
            publish(.failure("当前系统无法识别指针设备来源，增益未开启"))
            return
        }
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
    private var senders: [UInt64: MYBDeviceKind] = [:]
    /// Fractional extra displacement prevents small gains from rounding to zero.
    private var remainderY = 0.0
    /// Sender changes reset the complete motion baseline and pending output,
    /// preventing one physical device from inheriting another device's gain.
    private var previousSender: UInt64 = 0
    /// Tracks first matching mouse input for sparse, device-specific status.
    private var observedMouse = false
    /// Tracks first matching trackpad input independently of mouse activity, so
    /// enabling both devices never reports an unobserved category as active.
    private var observedTrackpad = false
    /// Consecutive timeout notifications allow bounded immediate tap recovery.
    private var timeoutCount = 0
    /// Desktop strips are precomputed once, outside the input callback.
    private let desktopStrips: [DesktopStrip]
    /// Most movement remains in this strip, requiring only a containment check.
    private var cachedStripIndex: Int?
    /// Marks this worker's replacement motion before any device lookup or
    /// fractional accounting, preventing synthetic input from feeding back.
    static let replacementMarker: Int64 = 0x4D59424F4F5354
    /// The upper 32 bits identify this utility's events; lower bits distinguish
    /// motion batches without relying on timestamps that posting may rewrite.
    private static let replacementMarkerMask: Int64 = -0x1_0000_0000
    /// Changes whenever a button, device, or tap transition invalidates queued
    /// motion. A random starting value also separates successive worker instances.
    private var replacementGeneration = UInt32.random(in: .min ... .max)
    /// Tags new output with the current batch so a delayed event from an earlier
    /// drag cannot acknowledge new output or overwrite the new position baseline.
    private var currentReplacementMarker: Int64 {
        (Self.replacementMarker & Self.replacementMarkerMask) | Int64(replacementGeneration)
    }
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
    /// Counts replacements until they return through this tap. Button, source,
    /// and tap transitions discard this count together with the pending position.
    private var pendingReplacements = 0

    /// Creates a worker without starting a thread or touching input permissions.
    init(configuration: MouseConfiguration) {
        self.configuration = configuration
        desktopStrips = Self.makeDesktopStrips(configuration.displays)
        replacementSource = CGEventSource(stateID: .combinedSessionState)
        replacementSource?.localEventsSuppressionInterval = 0
        replacementSource?.userData = currentReplacementMarker
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
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
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
            onStateChanged?(.waitingForInput(configuration.deviceDescription))
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

    /// Routes each identified device through its independent switch. True
    /// suppresses replaced physical input or obsolete synthetic output. Disabled
    /// and unidentified devices pass through, and current tagged output is never
    /// amplified again. Scroll and gesture events are outside the tap's mask.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout {
            timeoutCount += 1
            resetMotionTracking()
            if timeoutCount <= 3, let tap {
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
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker & Self.replacementMarkerMask == Self.replacementMarker & Self.replacementMarkerMask {
            // A queued position from before a device/button transition must not
            // reach the cursor after a new device has established its baseline.
            guard marker == currentReplacementMarker else { return true }
            guard pendingReplacements > 0 else { return false }
            precedingY = event.location.y
            pendingReplacements -= 1
            if pendingReplacements == 0 { pendingOutputY = nil }
            return false
        }
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            // Button events carry the actual click/release position. They form
            // a boundary even when drag packets contain no identifiable sender.
            resetMotionTracking(at: event.location)
            return false
        default:
            break
        }
        let sender = MYBEventSenderID(event)
        let senderChanged = sender != previousSender
        if senderChanged {
            previousSender = sender
            resetMotionTracking(at: event.location)
        }
        guard sender != 0 else {
            resetMotionTracking(at: event.location)
            return false
        }
        let classification: MYBDeviceKind
        if let cached = senders[sender] {
            classification = cached
        } else {
            classification = MYBClassifySender(sender)
            if senders.count >= 64 { senders.removeAll(keepingCapacity: true) }
            senders[sender] = classification
        }
        guard let gain = configuration.gain(for: classification) else {
            resetMotionTracking(at: event.location)
            return false
        }
        publishObservedDevice(classification)
        // The first position after a sender transition establishes a clean
        // baseline and passes through; subsequent movement receives the gain.
        guard !senderChanged else { return false }
        return transformMotionEvent(event, gain: gain)
    }

    /// Publishes only the first observation of each enabled device category.
    /// Mouse and trackpad alternation therefore adds no recurring main-thread
    /// work, while the status distinguishes one detected device from both.
    private func publishObservedDevice(_ kind: MYBDeviceKind) {
        switch kind {
        case .logitechMouse where !observedMouse:
            observedMouse = true
        case .trackpad where !observedTrackpad:
            observedTrackpad = true
        default:
            return
        }
        let devices = observedMouse && observedTrackpad ? "罗技鼠标和触控板"
            : observedMouse ? "罗技鼠标" : "触控板"
        onStateChanged?(.active(devices))
    }

    /// Starts a new motion baseline without changing or synthesizing input.
    /// Unidentified drag packets and button transitions may move the cursor far
    /// from the last boosted event. Discard its pending coordinate and rounding
    /// remainder together; late acknowledgements must not undo this reset.
    private func resetMotionTracking(at location: CGPoint? = nil) {
        replacementGeneration &+= 1
        replacementSource?.userData = currentReplacementMarker
        pendingReplacements = 0
        pendingOutputY = nil
        remainderY = 0
        precedingY = location.flatMap { $0.y.isFinite ? $0.y : nil }
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
    /// The caller authorizes the device and supplies its own saved multiplier;
    /// the transformation itself remains identical for mouse and trackpad input.
    func transformMotionEvent(_ event: CGEvent, gain: Double) -> Bool {
        let original = event.location
        guard original.x.isFinite, original.y.isFinite,
              let baseline = precedingY ?? CGEvent(source: nil)?.location.y,
              baseline.isFinite else {
            resetMotionTracking()
            return false
        }
        precedingY = original.y
        let acceleratedY = original.y - baseline
        let extra = acceleratedY * (gain - 1) + remainderY
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
        replacement.setIntegerValueField(.eventSourceUserData, value: currentReplacementMarker)
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
