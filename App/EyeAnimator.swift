import AppKit
import SwiftUI

/// Animates the menu bar eye.
/// - Opens (closed → open) when a hold starts, closes when it ends.
/// - While holding, blinks once every 6–12 s at random, so it reads as alive without being busy.
/// - Respects System Settings › Accessibility › Reduce motion: frames jump, no blinking.
/// Frames are template images `MenuBarEye0` (fully open) … `MenuBarEye4` (closed, with lashes).
/// Timers run only while a transition or the blink loop is active, so the cost when idle is zero.
@MainActor
final class EyeAnimator: ObservableObject {
    @Published private(set) var frameName = "MenuBarEye4"

    private var isOpen = false
    private var playTask: Task<Void, Never>?
    private var blinkTask: Task<Void, Never>?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Call on every reconcile tick; only state changes animate.
    func setAwake(_ awake: Bool) {
        guard awake != isOpen else { return }
        isOpen = awake
        blinkTask?.cancel()
        if awake {
            play([3, 2, 1, 0], frameMilliseconds: 50)
            scheduleBlinks()
        } else {
            play([1, 2, 3, 4], frameMilliseconds: 60)
        }
    }

    /// One blink on demand, e.g. when the user extends the timer.
    func blink() {
        guard isOpen else { return }
        play([1, 2, 3, 2, 1, 0], frameMilliseconds: 30)
    }

    private func scheduleBlinks() {
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                let wait = UInt64.random(in: 6_000...12_000) * 1_000_000
                try? await Task.sleep(nanoseconds: wait)
                guard !Task.isCancelled, let self, self.isOpen, !self.reduceMotion else { return }
                self.blink()
            }
        }
    }

    private func play(_ frames: [Int], frameMilliseconds: UInt64) {
        playTask?.cancel()
        let last = frames.last ?? 0
        guard !reduceMotion else {
            frameName = "MenuBarEye\(last)"
            return
        }
        playTask = Task { [weak self] in
            for frame in frames {
                guard !Task.isCancelled else { return }
                self?.frameName = "MenuBarEye\(frame)"
                try? await Task.sleep(nanoseconds: frameMilliseconds * 1_000_000)
            }
        }
    }
}
