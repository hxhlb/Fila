import AVFoundation

/// Activates and deactivates the shared audio session off the main thread.
///
/// Each call is a round trip to the media server and blocks until it answers;
/// iOS logs every one made on the main thread as a hang risk, and the
/// asynchronous `activate(options:completionHandler:)` arrived only in iOS 27.
/// One serial queue keeps the calls in the order they were made, so the
/// deactivation for a document just stopped cannot land after the activation
/// for the next one and stop it.
enum AudioSessionActivation {
    private static let queue = DispatchQueue(label: "wiki.qaq.fila.audio-session", qos: .userInitiated)

    /// The playback category — audible with the mute switch on — and an active
    /// session, then `ready` on the main actor. Playback starts in `ready`, so
    /// it never runs ahead of a deactivation still waiting on the queue.
    static func activate(then ready: @escaping @MainActor () -> Void = {}) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback)
            try? session.setActive(true)
            Task { @MainActor in ready() }
        }
    }

    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
