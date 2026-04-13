import Foundation
import SwiftUI

// MARK: - SpeechService

/// Lightweight state holder for voice input UI. The actual dictation UI is
/// presented by watchOS automatically when a SwiftUI TextField becomes focused
/// (the system input chooser includes dictation, scribble, and keyboard).
@MainActor
class SpeechService: ObservableObject {
    static let shared = SpeechService()

    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var error: String? = nil

    func beginDictation() {
        isRecording = true
        transcribedText = ""
        error = nil
    }

    func finishDictation(with text: String) {
        transcribedText = text
        isRecording = false
    }

    func cancelDictation() {
        transcribedText = ""
        isRecording = false
    }
}
