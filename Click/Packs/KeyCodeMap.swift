import Foundation

/// Mechvibes packs use Windows scan codes (a subset of USB HID page 0x07
/// translated through Windows' input layer). We translate them to macOS
/// virtual keycodes (kVK_*) so the same pack maps to the same physical key
/// across platforms.
///
/// The table covers the common keys Mechvibes packs key on. Anything not
/// listed falls through to the pack's default sample.
nonisolated
enum KeyCodeMap {
    /// Mechvibes keycode → macOS virtual keycode.
    static let mechvibesToMac: [Int: Int64] = [
        // Letters
        30: 0x00, // A
        48: 0x0B, // B
        46: 0x08, // C
        32: 0x02, // D
        18: 0x0E, // E
        33: 0x03, // F
        34: 0x05, // G
        35: 0x04, // H
        23: 0x22, // I
        36: 0x26, // J
        37: 0x28, // K
        38: 0x25, // L
        50: 0x2E, // M
        49: 0x2D, // N
        24: 0x1F, // O
        25: 0x23, // P
        16: 0x0C, // Q
        19: 0x0F, // R
        31: 0x01, // S
        20: 0x11, // T
        22: 0x20, // U
        47: 0x09, // V
        17: 0x0D, // W
        45: 0x07, // X
        21: 0x10, // Y
        44: 0x06, // Z

        // Top number row
        2: 0x12, // 1
        3: 0x13, // 2
        4: 0x14, // 3
        5: 0x15, // 4
        6: 0x17, // 5
        7: 0x16, // 6
        8: 0x1A, // 7
        9: 0x1C, // 8
       10: 0x19, // 9
       11: 0x1D, // 0

        // Punctuation row
       12: 0x1B, // -
       13: 0x18, // =
       26: 0x21, // [
       27: 0x1E, // ]
       43: 0x2A, // \
       39: 0x29, // ;
       40: 0x27, // '
       41: 0x32, // `
       51: 0x2B, // ,
       52: 0x2F, // .
       53: 0x2C, // /

        // Modifiers / specials
        1:  0x35, // Esc
       14: 0x33, // Backspace
       15: 0x30, // Tab
       28: 0x24, // Enter
       29: 0x3B, // Left Ctrl
       42: 0x38, // Left Shift
       54: 0x3C, // Right Shift
       56: 0x3A, // Left Alt
       57: 0x31, // Space
       58: 0x39, // Caps Lock

        // Function keys
       59: 0x7A, // F1
       60: 0x78, // F2
       61: 0x63, // F3
       62: 0x76, // F4
       63: 0x60, // F5
       64: 0x61, // F6
       65: 0x62, // F7
       66: 0x64, // F8
       67: 0x65, // F9
       68: 0x6D, // F10
       87: 0x67, // F11
       88: 0x6F, // F12

        // Arrows (extended)
      57416: 0x7E, // Up
      57424: 0x7D, // Down
      57419: 0x7B, // Left
      57421: 0x7C, // Right

        // Edit cluster
      57427: 0x73, // Home
      57423: 0x75, // Delete (forward)
      57417: 0x74, // Page Up
      57425: 0x77, // End
      57426: 0x79  // Page Down
    ]
}
