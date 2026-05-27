import ComposableArchitecture
import HexCore
#if DEBUG
import Inject
#endif
import SwiftUI

// MARK: - Menu Bar Button

/// Simple toggle button for the menu bar to start/stop call recording.
struct MenuBarCallRecordingButton: View {
	let store: StoreOf<CallRecordingFeature>

	var body: some View {
		if store.isRecording {
			Button {
				store.send(.stopRecording)
			} label: {
				HStack {
					Image(systemName: "record.circle.fill")
						.foregroundStyle(.red)
					Text("Stop Call Recording (\(store.recordingDuration.callDurationFormatted))")
				}
			}
		} else if store.isProcessing {
			Button {} label: {
				HStack {
					ProgressView()
						.controlSize(.small)
					Text("Processing call...")
				}
			}
			.disabled(true)
		} else {
			Button {
				store.send(.startRecording)
			} label: {
				HStack {
					Image(systemName: "phone.circle")
					Text("Record Call")
				}
			}
		}
	}
}

// MARK: - Call Recording Settings Section

struct CallRecordingSectionView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Toggle("Enable Call Recording", isOn: $store.hexSettings.callRecordingEnabled)

			if store.hexSettings.callRecordingEnabled {
				// User name for transcript labels
				HStack {
					Text("Your Name")
					Spacer()
					TextField("Name", text: $store.hexSettings.callRecordingUserName)
						.textFieldStyle(.roundedBorder)
						.frame(width: 150)
				}

				// Storage path
				HStack {
					Text("Storage")
					Spacer()
					Text(store.hexSettings.callRecordingStoragePath ?? "~/CallBank")
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)

					Button("Choose...") {
						chooseStoragePath()
					}
				}

				Toggle("Auto-commit to git", isOn: $store.hexSettings.callRecordingAutoCommit)

				Toggle("Claude AI cleanup", isOn: $store.hexSettings.callRecordingClaudeCleanup)

				if store.hexSettings.callRecordingClaudeCleanup {
					Text("Cleans up transcription errors, infers speaker names, and generates titles and summaries using Claude.")
						.settingsCaption()
				}
			}
		} header: {
			Label("Call Recording", systemImage: "phone.badge.waveform")
		}
	}

	private func chooseStoragePath() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.message = "Choose where to save call transcripts"
		panel.prompt = "Select Folder"

		if panel.runModal() == .OK, let url = panel.url {
			store.send(.binding(.set(\.hexSettings.callRecordingStoragePath, url.path)))
		}
	}
}

// MARK: - Processing Progress View

struct CallProcessingProgressView: View {
	let stage: CallProcessingStage?
	let progress: Double

	var body: some View {
		VStack(spacing: 12) {
			ProgressView(value: progress, total: 1.0) {
				Text(stageLabel)
					.font(.headline)
			}
			.progressViewStyle(.linear)

			if let stage, stage != .complete {
				Text(stageDescription)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.padding()
		.frame(maxWidth: 400)
	}

	private var stageLabel: String {
		guard let stage else { return "Preparing..." }
		switch stage {
		case .transcribingMic: return "Transcribing your audio..."
		case .transcribingSystem: return "Transcribing call audio..."
		case .diarizing: return "Identifying speakers..."
		case .mergingTimeline: return "Building timeline..."
		case .cleaningUp: return "AI cleanup pass..."
		case .savingTranscript: return "Saving transcript..."
		case .complete: return "Complete!"
		case .failed: return "Processing failed"
		}
	}

	private var stageDescription: String {
		guard let stage else { return "" }
		switch stage {
		case .transcribingMic: return "Using Parakeet TDT on your microphone track"
		case .transcribingSystem: return "Using Parakeet TDT on the call audio track"
		case .diarizing: return "Identifying speaker turns"
		case .mergingTimeline: return "Interleaving speaker segments by timestamp"
		case .cleaningUp: return "Claude is fixing jargon and inferring speaker names"
		case .savingTranscript: return "Writing markdown and metadata to disk"
		case .complete: return ""
		case .failed: return ""
		}
	}
}

// MARK: - Transcript Review View

struct CallTranscriptReviewView: View {
	let transcript: CallTranscript
	let onSave: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			// Header
			HStack {
				VStack(alignment: .leading) {
					Text(transcript.title ?? "Untitled Call")
						.font(.title2.bold())
					HStack(spacing: 12) {
						Label(transcript.duration.callDurationFormatted, systemImage: "clock")
						if !transcript.participants.isEmpty {
							Label(transcript.participants.joined(separator: ", "), systemImage: "person.2")
						}
					}
					.font(.caption)
					.foregroundStyle(.secondary)
				}
				Spacer()
				HStack(spacing: 8) {
					Button("Dismiss") { onDismiss() }
					Button("Save") { onSave() }
						.buttonStyle(.borderedProminent)
				}
			}

			if let summary = transcript.summary {
				GroupBox("Summary") {
					Text(summary)
						.font(.body)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}

			if !transcript.tags.isEmpty {
				HStack {
					ForEach(transcript.tags, id: \.self) { tag in
						Text(tag)
							.font(.caption)
							.padding(.horizontal, 8)
							.padding(.vertical, 2)
							.background(.quaternary)
							.clipShape(Capsule())
					}
				}
			}

			Divider()

			// Transcript segments
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 8) {
					ForEach(transcript.segments) { segment in
						HStack(alignment: .top, spacing: 8) {
							Text(formatTimestamp(segment.startTime))
								.font(.caption.monospaced())
								.foregroundStyle(.tertiary)
								.frame(width: 50, alignment: .trailing)

							Text(segment.speakerName ?? segment.speakerId)
								.font(.caption.bold())
								.foregroundStyle(colorForSpeaker(segment.speakerId))
								.frame(width: 80, alignment: .leading)

							Text(segment.text)
								.font(.body)
								.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
				}
				.padding(.horizontal)
			}
		}
		.padding()
		.frame(minWidth: 600, minHeight: 400)
	}

	private func formatTimestamp(_ seconds: TimeInterval) -> String {
		let m = Int(seconds) / 60
		let s = Int(seconds) % 60
		return String(format: "%02d:%02d", m, s)
	}

	private func colorForSpeaker(_ id: String) -> Color {
		let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
		let hash = abs(id.hashValue)
		return colors[hash % colors.count]
	}
}

// MARK: - Call Recording Settings/Status View (for the "Calls" tab)

struct CallRecordingSettingsView: View {
	let store: StoreOf<CallRecordingFeature>

	var body: some View {
		Form {
			// Recording control
			Section("Recording") {
				if store.isRecording {
					HStack {
						Circle()
							.fill(.red)
							.frame(width: 8, height: 8)
						Text("Recording: \(store.recordingDuration.callDurationFormatted)")
							.font(.body.monospaced())
						Spacer()
						Button("Stop") {
							store.send(.stopRecording)
						}
						.buttonStyle(.borderedProminent)
						.tint(.red)
					}
				} else if store.isProcessing {
					CallProcessingProgressView(
						stage: store.processingStage,
						progress: store.processingProgress
					)
				} else {
					Button {
						store.send(.startRecording)
					} label: {
						Label("Start Call Recording", systemImage: "phone.badge.waveform")
					}
				}
			}

			// Error display
			if let error = store.error {
				Section {
					HStack {
						Image(systemName: "exclamationmark.triangle")
							.foregroundStyle(.yellow)
						Text(error)
							.font(.caption)
					}
					Button("Dismiss") {
						store.send(.clearError)
					}
				}
			}

			// Test with sample audio (bypasses hardware capture)
			Section("Pipeline Test") {
				Button {
					let testDir = URL(fileURLWithPath: "/tmp/hex-test-audio")
					let micURL = testDir.appendingPathComponent("mic_track.wav")
					if FileManager.default.fileExists(atPath: micURL.path) {
						store.send(.testWithSampleAudio(micURL: micURL))
					}
				} label: {
					Label("Test with Sample Audio", systemImage: "waveform.badge.magnifyingglass")
				}
				.disabled(store.isProcessing || store.isRecording)

				Text("Runs the mic transcription pipeline on pre-generated test audio in /tmp/hex-test-audio/. Generate with: ./scripts/generate-test-audio.sh")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}
}
