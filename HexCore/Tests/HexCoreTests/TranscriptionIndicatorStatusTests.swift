import Testing
@testable import HexCore

struct TranscriptionIndicatorStatusTests {
    @Test func recordingPlusPrewarmingWinsOverPlainRecordingAndTranscribing() {
        #expect(
            TranscriptionIndicatorStatus.resolve(
                isRecording: true,
                isPrewarming: true,
                isTranscribing: true
            ) == .recordingPreparing
        )
    }

    @Test func recordingWinsOverStaleTranscribingFlag() {
        #expect(
            TranscriptionIndicatorStatus.resolve(
                isRecording: true,
                isPrewarming: false,
                isTranscribing: true
            ) == .recording
        )
    }

    @Test func prewarmingWinsOverTranscribingWhenNoRecordingIsActive() {
        #expect(
            TranscriptionIndicatorStatus.resolve(
                isRecording: false,
                isPrewarming: true,
                isTranscribing: true
            ) == .preparingModel
        )
    }

    @Test func transcribingIsOnlyShownWhenNoRecordingOrPreparationIsActive() {
        #expect(
            TranscriptionIndicatorStatus.resolve(
                isRecording: false,
                isPrewarming: false,
                isTranscribing: true
            ) == .transcribing
        )
    }

    @Test func noActiveWorkIsHidden() {
        #expect(
            TranscriptionIndicatorStatus.resolve(
                isRecording: false,
                isPrewarming: false,
                isTranscribing: false
            ) == .hidden
        )
    }
}
