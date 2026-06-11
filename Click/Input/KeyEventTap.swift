import CoreGraphics
import Foundation
import os

/// Owns a `CGEventTap` listening for global key-down events. Pass-through only;
/// it never consumes or modifies the user's keystrokes.
///
/// Events are surfaced through an `AsyncStream<KeyEvent>` exposed by `events()`.
/// The tap is installed on the **main runloop** — the C callback does only a
/// constant amount of work (read keycode + yield) before returning, so it
/// doesn't impact UI responsiveness. If the system disables the tap (e.g. it
/// took too long once), the callback re-enables it on the next event.
@MainActor
final class KeyEventTap {
    private static let log = Logger(subsystem: "brandon.Click", category: "eventtap")

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var continuation: AsyncStream<KeyEvent>.Continuation?
    private var stream: AsyncStream<KeyEvent>?
    private var retainedSelf: Unmanaged<KeyEventTap>?

    /// Stream of key-down events.
    func events() -> AsyncStream<KeyEvent> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream.makeStream(of: KeyEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    /// `true` while a tap is installed and currently enabled. macOS disables
    /// taps it deems slow and destroys them when Input Monitoring is revoked, so
    /// callers should poll this to detect a tap that died silently.
    var isHealthy: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Installs the tap. Returns `false` if Input Monitoring permission is missing
    /// or the tap could not be created.
    @discardableResult
    func start() -> Bool {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
        return install()
    }

    /// Tears the tap down and ends the event stream.
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        runLoopSource = nil
        continuation?.finish()
        continuation = nil
        stream = nil
        // Balance the passRetained in install(). Safe to release here: the
        // callback fires on the same main runloop the tap was attached to, so
        // no callback can be in flight on another thread when stop() runs.
        retainedSelf?.release()
        retainedSelf = nil
    }

    private func install() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        // Retain ourselves through the tap's userInfo so the C callback can't
        // dangle if the tap outlives its Swift owner.
        let unmanaged = Unmanaged.passRetained(self)
        retainedSelf = unmanaged
        let context = unmanaged.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: keyEventTapCallback,
            userInfo: context
        ) else {
            Self.log.error("CGEvent.tapCreate failed (Input Monitoring not granted?)")
            retainedSelf?.release()
            retainedSelf = nil
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

}

/// Hot path: invoked by Core Graphics on the main thread. Keep it short.
/// No keycode logging — keystrokes never leave the process.
private let keyEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<KeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .keyDown:
        // Drop OS auto-repeat events — holding a key down fires keyDown at
        // ~30 Hz, which would play a continuous machine-gun click. We only
        // want the genuine initial press.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            break
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let ts = event.timestamp
        MainActor.assumeIsolated {
            me.yield(keyCode: code, timestamp: ts)
        }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated {
            me.reenable()
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

extension KeyEventTap {
    fileprivate func yield(keyCode: Int64, timestamp: UInt64) {
        continuation?.yield(KeyEvent(keyCode: keyCode, timestamp: timestamp))
    }

    fileprivate func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
