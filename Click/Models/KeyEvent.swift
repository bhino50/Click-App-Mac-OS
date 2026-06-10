import Foundation

/// A single global keystroke captured by `KeyEventTap`.
///
/// `keyCode` is the macOS virtual keycode (kVK_*). `timestamp` is the
/// `mach_absolute_time` value at the moment the event was observed so
/// downstream consumers can measure inter-key timing for velocity.
nonisolated
struct KeyEvent: Sendable, Equatable {
    let keyCode: Int64
    let timestamp: UInt64
}
