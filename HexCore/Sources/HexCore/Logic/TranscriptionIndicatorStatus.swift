public enum TranscriptionIndicatorStatus: Equatable {
    case hidden
    case recording
    case recordingPreparing
    case transcribing
    case preparingModel

    public static func resolve(
        isRecording: Bool,
        isPrewarming: Bool,
        isTranscribing: Bool
    ) -> Self {
        if isRecording, isPrewarming {
            return .recordingPreparing
        } else if isRecording {
            return .recording
        } else if isPrewarming {
            return .preparingModel
        } else if isTranscribing {
            return .transcribing
        } else {
            return .hidden
        }
    }
}
