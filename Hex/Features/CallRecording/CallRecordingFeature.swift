import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import SwiftUI

private let logger = HexLog.callRecording

@Reducer
struct CallRecordingFeature {
	@ObservableState
	struct State {
		// Recording state
		var isRecording: Bool = false
		var recordingDuration: TimeInterval = 0
		var micLevel: Meter = .init(averagePower: 0, peakPower: 0)
		var recordingStartTime: Date?

		// Processing state
		var isProcessing: Bool = false
		var processingStage: CallProcessingStage?
		var processingProgress: Double = 0

		// Post-call review
		var currentTranscript: CallTranscript?
		var showingReview: Bool = false

		// Setup state
		var availableDevices: [AudioInputDevice] = []

		// Error state
		var error: String?

		@Shared(.hexSettings) var hexSettings: HexSettings
	}

	enum Action {
		case task

		// Recording
		case startRecording
		case stopRecording
		case recordingStopped(micURL: URL, duration: TimeInterval)
		case micLevelUpdated(Meter)
		case durationTick

		// Processing pipeline
		case startProcessing(micURL: URL, duration: TimeInterval)
		case processingStageChanged(CallProcessingStage)
		case processingComplete(CallTranscript)
		case processingFailed(String)

		// Review
		case dismissReview
		case saveTranscript(CallTranscript)
		case transcriptSaved

		// Setup
		case devicesLoaded([AudioInputDevice])

		// Error
		case clearError

		// Debug/Test
		case testWithSampleAudio(micURL: URL)
	}

	enum CancelID {
		case metering
		case durationTimer
		case processing
	}

	@Dependency(\.callRecording) var callRecording
	@Dependency(\.transcription) var transcription
	@Dependency(\.callCleanup) var callCleanup
	@Dependency(\.continuousClock) var clock
	@Dependency(\.date.now) var now

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case .task:
				return .merge(
					.run { send in
						let devices = await callRecording.getAudioInputDevices()
						await send(.devicesLoaded(devices))
					},
					startMeteringEffect()
				)

			// MARK: - Recording

			case .startRecording:
				guard !state.isRecording else { return .none }
				state.isRecording = true
				state.recordingStartTime = now
				state.error = nil

				let micID = state.hexSettings.selectedMicrophoneID

				return .merge(
					.run { send in
						do {
							try await callRecording.startRecording(micID)
							logger.notice("Call recording started")
						} catch {
							logger.error("Failed to start recording: \(error.localizedDescription)")
							await send(.processingFailed(error.localizedDescription))
						}
					},
					startDurationTimer()
				)

			case .stopRecording:
				guard state.isRecording else { return .none }
				state.isRecording = false
				let duration = state.recordingDuration
				state.recordingDuration = 0

				return .merge(
					.cancel(id: CancelID.durationTimer),
					.run { send in
						let micURL = await callRecording.stopRecording()
						logger.notice("Call recording stopped — \(String(format: "%.0f", duration))s")
						await send(.recordingStopped(
							micURL: micURL,
							duration: duration
						))
					}
				)

			case let .recordingStopped(micURL, duration):
				return .send(.startProcessing(
					micURL: micURL,
					duration: duration
				))

			case let .micLevelUpdated(level):
				state.micLevel = level
				return .none

			case .durationTick:
				if let start = state.recordingStartTime {
					state.recordingDuration = now.timeIntervalSince(start)
				}
				return .none

			// MARK: - Processing Pipeline

			case let .startProcessing(micURL, duration):
				state.isProcessing = true
				state.processingProgress = 0

				return .run { send in
					await send(.processingStageChanged(.transcribingMic))
					do {
						let transcript = try await runProcessingPipeline(
							micURL: micURL,
							duration: duration,
							send: send
						)
						await send(.processingComplete(transcript))
					} catch {
						logger.error("Processing failed: \(error.localizedDescription)")
						await send(.processingFailed(error.localizedDescription))
					}
				}
				.cancellable(id: CancelID.processing)

			case let .processingStageChanged(stage):
				state.processingStage = stage
				switch stage {
				case .transcribingMic: state.processingProgress = 0.1
				case .transcribingSystem: state.processingProgress = 0.3
				case .diarizing: state.processingProgress = 0.5
				case .mergingTimeline: state.processingProgress = 0.7
				case .cleaningUp: state.processingProgress = 0.8
				case .savingTranscript: state.processingProgress = 0.95
				case .complete: state.processingProgress = 1.0
				case .failed: break
				}
				return .none

			case let .processingComplete(transcript):
				state.isProcessing = false
				state.processingStage = .complete
				state.processingProgress = 1.0
				state.currentTranscript = transcript
				state.showingReview = true
				return .none

			case let .processingFailed(error):
				state.isProcessing = false
				state.isRecording = false
				state.processingStage = .failed
				state.error = error
				return .merge(
					.cancel(id: CancelID.durationTimer),
					.cancel(id: CancelID.processing)
				)

			// MARK: - Review

			case .dismissReview:
				state.showingReview = false
				state.currentTranscript = nil
				return .none

			case let .saveTranscript(transcript):
				return .run { send in
					do {
						try saveTranscriptToDisk(transcript)
						logger.notice("Transcript saved: \(transcript.title ?? "Untitled")")
						await send(.transcriptSaved)
					} catch {
						logger.error("Failed to save transcript: \(error.localizedDescription)")
						await send(.processingFailed(error.localizedDescription))
					}
				}

			case .transcriptSaved:
				state.showingReview = false
				state.currentTranscript = nil
				return .none

			// MARK: - Setup

			case let .devicesLoaded(devices):
				state.availableDevices = devices
				return .none

			case .clearError:
				state.error = nil
				return .none

			// MARK: - Debug/Test

			case let .testWithSampleAudio(micURL):
				guard !state.isProcessing else { return .none }
				let duration: TimeInterval
				if let file = try? AVAudioFile(forReading: micURL) {
					duration = Double(file.length) / file.fileFormat.sampleRate
				} else {
					duration = 30
				}
				logger.notice("Test mode: processing sample audio mic=\(micURL.lastPathComponent) duration=\(String(format: "%.1f", duration))s")
				return .send(.startProcessing(micURL: micURL, duration: duration))
			}
		}
	}
}

// MARK: - Effects

private extension CallRecordingFeature {
	func startMeteringEffect() -> Effect<Action> {
		.run { send in
			for await level in await callRecording.observeMicLevel() {
				await send(.micLevelUpdated(level))
			}
		}
		.cancellable(id: CancelID.metering, cancelInFlight: true)
	}

	func startDurationTimer() -> Effect<Action> {
		.run { send in
			for await _ in clock.timer(interval: .seconds(1)) {
				await send(.durationTick)
			}
		}
		.cancellable(id: CancelID.durationTimer, cancelInFlight: true)
	}
}

// MARK: - Processing Pipeline

private extension CallRecordingFeature {
	func runProcessingPipeline(
		micURL: URL,
		duration: TimeInterval,
		send: Send<Action>
	) async throws -> CallTranscript {
		@Shared(.hexSettings) var hexSettings: HexSettings
		let userName = hexSettings.callRecordingUserName

		await send(.processingStageChanged(.transcribingMic))
		let micText = try await transcription.transcribe(micURL, hexSettings.selectedModel, .init()) { _ in }
		logger.notice("Mic transcription: \(micText.count) chars")

		await send(.processingStageChanged(.mergingTimeline))
		var segments: [CallSegment] = []

		if !micText.isEmpty {
			segments.append(CallSegment(
				speakerId: "mic",
				speakerName: userName,
				text: micText,
				startTime: 0,
				endTime: duration
			))
		}

		var transcript = CallTranscript(
			date: Date(),
			duration: duration,
			segments: segments,
			micAudioPath: micURL
		)

		// 5. Claude cleanup (optional)
		if hexSettings.callRecordingClaudeCleanup {
			await send(.processingStageChanged(.cleaningUp))
			do {
				let result = try await callCleanup.cleanup(segments, nil)
				transcript.title = result.title
				transcript.summary = result.summary
				transcript.participants = result.participants
				transcript.tags = result.tags
				transcript.segments = result.cleanedSegments
				transcript.hasBeenCleaned = true
				logger.notice("Claude cleanup applied — title: '\(result.title)'")
			} catch {
				logger.warning("Claude cleanup failed, using raw transcript: \(error.localizedDescription)")
			}
		}

		// 6. Save
		await send(.processingStageChanged(.savingTranscript))
		try saveTranscriptToDisk(transcript)

		await send(.processingStageChanged(.complete))
		return transcript
	}

	func saveTranscriptToDisk(_ transcript: CallTranscript) throws {
		@Shared(.hexSettings) var hexSettings: HexSettings

		// Determine storage path
		let basePath: URL
		if let customPath = hexSettings.callRecordingStoragePath {
			basePath = URL(fileURLWithPath: customPath)
		} else {
			basePath = FileManager.default.homeDirectoryForCurrentUser
				.appendingPathComponent("CallBank", isDirectory: true)
		}

		// Create directory structure: calls/YYYY/MM/
		let calendar = Calendar.current
		let year = String(calendar.component(.year, from: transcript.date))
		let month = String(format: "%02d", calendar.component(.month, from: transcript.date))
		let callsDir = basePath
			.appendingPathComponent("calls", isDirectory: true)
			.appendingPathComponent(year, isDirectory: true)
			.appendingPathComponent(month, isDirectory: true)
		try FileManager.default.createDirectory(at: callsDir, withIntermediateDirectories: true)

		// Generate filename
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd'T'HH-mm"
		let dateStr = formatter.string(from: transcript.date)
		let titleSlug = (transcript.title ?? "untitled")
			.lowercased()
			.replacingOccurrences(of: " ", with: "-")
			.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
			.joined()
			.prefix(50)
		let filename = "\(dateStr)-\(titleSlug)"

		// Save markdown
		let mdPath = callsDir.appendingPathComponent("\(filename).md")
		let markdown = transcript.toMarkdown()
		try markdown.write(to: mdPath, atomically: true, encoding: .utf8)
		logger.notice("Saved transcript to \(mdPath.path)")

		// Save JSON metadata
		let jsonPath = callsDir.appendingPathComponent("\(filename).json")
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		let jsonData = try encoder.encode(transcript)
		try jsonData.write(to: jsonPath, options: .atomic)

		// Auto-commit if enabled
		if hexSettings.callRecordingAutoCommit {
			autoCommit(basePath: basePath, message: "Add call: \(transcript.title ?? "Untitled") (\(dateStr))")
		}
	}

	func autoCommit(basePath: URL, message: String) {
		let process = Process()
		process.currentDirectoryURL = basePath
		process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
		process.arguments = ["add", "-A"]

		let commitProcess = Process()
		commitProcess.currentDirectoryURL = basePath
		commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
		commitProcess.arguments = ["commit", "-m", message]

		do {
			try process.run()
			process.waitUntilExit()
			try commitProcess.run()
			commitProcess.waitUntilExit()
			logger.notice("Auto-committed transcript to git")
		} catch {
			logger.warning("Git auto-commit failed: \(error.localizedDescription)")
		}
	}
}

// MARK: - Duration Formatting

extension TimeInterval {
	var callDurationFormatted: String {
		let totalSeconds = Int(self)
		let hours = totalSeconds / 3600
		let minutes = (totalSeconds % 3600) / 60
		let seconds = totalSeconds % 60
		if hours > 0 {
			return String(format: "%d:%02d:%02d", hours, minutes, seconds)
		}
		return String(format: "%02d:%02d", minutes, seconds)
	}
}
