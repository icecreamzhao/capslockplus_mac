import Foundation
import AVFoundation

/// 播放离线词库里抽出来的读音（朗文 mdd 里的 mp3）。
final class AudioPlayer {
    static let shared = AudioPlayer()

    static var audioRoot: String {
        NSString(string: "~/.config/capslock-plus-mac/audio").expandingTildeInPath
    }

    private var player: AVAudioPlayer?

    /// path 形如 "hwd/bre/7/abandon_v0205.mp3"，相对 audioRoot。
    @discardableResult
    func play(relativePath: String) -> Bool {
        let file = (Self.audioRoot as NSString).appendingPathComponent(relativePath)
        return play(file: file, logPath: relativePath)
    }

    /// 绝对路径播放：词典资源目录 dict-assets/<source>/ 里抽出来的 spx/mp3 走这里。
    @discardableResult
    func play(file: String) -> Bool {
        play(file: file, logPath: file)
    }

    private func play(file: String, logPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: file) else {
            Log.warn("audio missing file=\(logPath)")
            return false
        }
        do {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: file))
            player?.volume = 1.0
            player?.play()
            Log.info("audio play file=\(logPath)")
            return true
        } catch {
            Log.warn("audio failed file=\(logPath) reason=\(error.localizedDescription)")
            return false
        }
    }
}
