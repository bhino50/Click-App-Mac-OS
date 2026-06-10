import AVFoundation
import Foundation

/// A fixed-size ring of `AVAudioPlayerNode`s, each attached to the mixer at
/// init time. Pick the next free node round-robin so overlapping keystrokes
/// can play concurrently without allocating during playback.
nonisolated
final class PlayerNodePool: @unchecked Sendable {
    let nodes: [AVAudioPlayerNode]
    private var cursor: Int = 0

    init(engine: AVAudioEngine, mixer: AVAudioMixerNode, format: AVAudioFormat, size: Int = 16) {
        var built: [AVAudioPlayerNode] = []
        built.reserveCapacity(size)
        for _ in 0..<size {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: mixer, format: format)
            built.append(node)
        }
        self.nodes = built
    }

    /// Returns the next player node in the rotation.
    func next() -> AVAudioPlayerNode {
        let node = nodes[cursor]
        cursor = (cursor + 1) % nodes.count
        return node
    }

    func startAll() {
        for node in nodes where !node.isPlaying {
            node.play()
        }
    }

    func stopAll() {
        for node in nodes {
            node.stop()
        }
    }

    /// Detaches every player node from `engine`. Call before recreating the
    /// pool so old nodes don't linger after a configuration change.
    func detachAll(from engine: AVAudioEngine) {
        for node in nodes {
            node.stop()
            engine.detach(node)
        }
    }
}
