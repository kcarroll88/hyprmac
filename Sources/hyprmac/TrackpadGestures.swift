import AppKit
import HyprCore

/// Three-finger horizontal swipe to change workspace.
///
/// Reads the trackpad directly through MultitouchSupport, because nothing public
/// reports how many fingers are down:
///
///   - A global `NSEvent` monitor receives no gesture events at all.
///   - A `CGEventTap` does receive them, but `NSEvent.touches` on a reconstructed
///     CGEvent always reports one touch, whatever your hand is doing.
///
/// MultitouchSupport is private but needs no SIP change; Input Monitoring covers
/// it. It has been stable for over a decade and is what every trackpad utility on
/// the platform uses.
final class TrackpadGestureMonitor {
    /// MTTouch is 96 bytes on 64-bit. Only three fields matter, so they are read
    /// by offset rather than by modelling the whole struct — which also avoids
    /// Swift refusing a Swift struct inside a `@convention(c)` signature.
    private enum Touch {
        static let stride = 96
        static let identifier = 16
        static let x = 32
        static let y = 36
    }

    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias ContactCallback =
        @convention(c) (DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// Callbacks are C function pointers with no refcon on this API, so the live
    /// monitor is reached through a file-scope box.
    nonisolated(unsafe) fileprivate static var active: TrackpadGestureMonitor?

    private var started = false
    private var startPositions: [Int32: CGPoint] = [:]
    /// Latched once a swipe fires, so one continuous gesture cannot rattle through
    /// several workspaces before the fingers lift.
    private var consumed = false

    /// Horizontal swipes step workspaces; vertical ones open and close the
    /// overview. Both come from the same gesture, separated by which axis won.
    var onSwipe: ((Direction) -> Void)?

    private let fingers: Int32
    private let threshold: CGFloat
    private let inverted: Bool

    init(fingers: Int, threshold: CGFloat, inverted: Bool) {
        self.fingers = Int32(max(2, fingers))
        self.threshold = max(0.02, threshold)
        self.inverted = inverted
    }

    func start() {
        guard !started else { return }
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            log("trackpad: MultitouchSupport unavailable; gestures disabled")
            return
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let createList = symbol("MTDeviceCreateList", (@convention(c) () -> CFArray?).self),
              let register = symbol("MTRegisterContactFrameCallback",
                                    (@convention(c) (DeviceRef, ContactCallback) -> Void).self),
              let deviceStart = symbol("MTDeviceStart", (@convention(c) (DeviceRef, Int32) -> Void).self) else {
            log("trackpad: MultitouchSupport symbols missing; gestures disabled")
            return
        }

        // Register on every device. A Mac reports more than one, and the one
        // `MTDeviceCreateDefault` hands back is not necessarily the trackpad —
        // registering only on it produces no callbacks at all.
        let devices = (createList() as? [AnyObject]) ?? []
        guard !devices.isEmpty else {
            log("trackpad: no multitouch device; gestures disabled")
            return
        }
        Self.active = self
        for device in devices {
            let ref = unsafeBitCast(device, to: DeviceRef.self)
            register(ref, trackpadContactCallback)
            deviceStart(ref, 0)
        }
        started = true
        log("trackpad: watching \(devices.count) device(s) for \(fingers)-finger swipes")
    }

    func stop() {
        // The framework offers no clean unregister, so the callback is simply
        // detached from any live monitor.
        if Self.active === self { Self.active = nil }
        started = false
        reset()
    }

    private func reset() {
        startPositions.removeAll()
        consumed = false
    }

    fileprivate func handle(touches: UnsafeMutableRawPointer?, count: Int32) {
        guard count == fingers, let touches else {
            if count < fingers { reset() }
            return
        }

        var current: [Int32: CGPoint] = [:]
        for index in 0..<Int(count) {
            let base = touches.advanced(by: index * Touch.stride)
            let id = base.load(fromByteOffset: Touch.identifier, as: Int32.self)
            let x = base.load(fromByteOffset: Touch.x, as: Float.self)
            let y = base.load(fromByteOffset: Touch.y, as: Float.self)
            current[id] = CGPoint(x: CGFloat(x), y: CGFloat(y))
        }

        guard !startPositions.isEmpty else {
            startPositions = current
            consumed = false
            return
        }
        guard !consumed else { return }

        // Average the fingers still down: a swipe is the whole hand travelling
        // together, and averaging ignores the one finger that always drifts.
        var totalX: CGFloat = 0, totalY: CGFloat = 0, counted = 0
        for (id, position) in current {
            guard let origin = startPositions[id] else { continue }
            totalX += position.x - origin.x
            totalY += position.y - origin.y
            counted += 1
        }
        guard counted > 0 else { return }

        let dx = totalX / CGFloat(counted)
        let dy = totalY / CGFloat(counted)

        // One axis has to clearly win, or a lazy diagonal fires both meanings.
        let direction: Direction
        if abs(dx) > threshold, abs(dx) > abs(dy) * 1.5 {
            // The workspaces move with your fingers: swipe right, go right. Set
            // `gestures { natural = false }` for the inverse, which is how macOS
            // Spaces reads it.
            direction = (inverted ? dx < 0 : dx > 0) ? .right : .left
        } else if abs(dy) > threshold, abs(dy) > abs(dx) * 1.5 {
            // Trackpad y grows upward, so fingers moving towards you is negative.
            direction = dy < 0 ? .down : .up
        } else {
            return
        }

        consumed = true
        DispatchQueue.main.async { [weak self] in self?.onSwipe?(direction) }
    }
}

/// Runs on the multitouch device's own thread, so it does no work beyond handing
/// the frame over; the dispatch back to main happens inside `handle`.
private func trackpadContactCallback(device: UnsafeMutableRawPointer?,
                                     touches: UnsafeMutableRawPointer?,
                                     count: Int32,
                                     timestamp: Double,
                                     frame: Int32) -> Int32 {
    TrackpadGestureMonitor.active?.handle(touches: touches, count: count)
    return 0
}
