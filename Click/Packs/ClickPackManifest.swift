import Foundation

/// JSON shape of a native `manifest.json` for a `.clickpack`.
///
/// `keyMap` maps stringified macOS virtual keycodes to an ordered list of
/// audio files (relative to the pack root). When more than one file is given
/// for a keycode, the loader selects one at random per keystroke for variety.
/// `defaultSound` is used for any key not present in `keyMap`.
nonisolated
struct ClickPackManifest: Codable, Sendable {
    let name: String
    let author: String?
    let version: String?
    let defaultSound: String?
    let keyMap: [String: [String]]?

    enum CodingKeys: String, CodingKey {
        case name
        case author
        case version
        case defaultSound = "defaultSound"
        case keyMap = "keyMap"
    }
}
