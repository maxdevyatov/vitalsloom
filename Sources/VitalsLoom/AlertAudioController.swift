import AppKit
import Foundation

@MainActor
final class AlertAudioController {
    private var soundTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var currentSound: NSSound?

    var isPlaying: Bool { soundTask != nil }

    func start() {
        guard soundTask == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated, .latencyCritical],
            reason: "VitalsLoom vital alert is active")
        soundTask = Task {
            while !Task.isCancelled {
                if let sound = NSSound(named: NSSound.Name("Sosumi")) ?? NSSound(named: NSSound.Name("Funk")) {
                    sound.volume = 1
                    currentSound = sound
                    sound.play()
                } else {
                    NSSound.beep()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        soundTask?.cancel()
        soundTask = nil
        currentSound?.stop()
        currentSound = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
