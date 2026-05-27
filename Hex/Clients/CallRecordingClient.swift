import AudioToolbox
import AVFoundation
import ComposableArchitecture
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let logger = HexLog.callRecording

// MARK: - Client Interface

@DependencyClient
struct CallRecordingClient {
	/// Start recording microphone audio.
	var startRecording: @Sendable (_ micDeviceUID: String?) async throws -> Void = { _ in }
	/// Stop recording and return the mic audio file path.
	var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
	/// Check if currently recording
	var isRecording: @Sendable () async -> Bool = { false }
	/// Get available audio input devices.
	var getAudioInputDevices: @Sendable () async -> [AudioInputDevice] = { [] }
	/// Observe audio levels from mic track
	var observeMicLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
	/// Get recording duration so far
	var currentDuration: @Sendable () async -> TimeInterval = { 0 }
	/// Cleanup resources
	var cleanup: @Sendable () async -> Void = {}
}

extension CallRecordingClient: DependencyKey {
	static var liveValue: Self {
		let live = CallRecordingClientLive()
		return Self(
			startRecording: { try await live.startRecording(micDeviceUID: $0) },
			stopRecording: { await live.stopRecording() },
			isRecording: { await live.isRecording },
			getAudioInputDevices: { await live.getAudioInputDevices() },
			observeMicLevel: { await live.observeMicLevel() },
			currentDuration: { await live.currentDuration },
			cleanup: { await live.cleanup() }
		)
	}
}

extension DependencyValues {
	var callRecording: CallRecordingClient {
		get { self[CallRecordingClient.self] }
		set { self[CallRecordingClient.self] = newValue }
	}
}

// MARK: - Live Implementation

actor CallRecordingClientLive {
	private var micEngine: AVAudioEngine?
	private var micFile: AVAudioFile?
	private var micURL: URL?
	private var _isRecording = false
	private var recordingStartTime: Date?
	private var meterContinuation: AsyncStream<Meter>.Continuation?

	var isRecording: Bool { _isRecording }

	var currentDuration: TimeInterval {
		guard let start = recordingStartTime else { return 0 }
		return Date().timeIntervalSince(start)
	}

	func startRecording(micDeviceUID: String?) async throws {
		guard !_isRecording else {
			logger.warning("Already recording, ignoring startRecording")
			return
		}

		let tempDir = FileManager.default.temporaryDirectory
		let sessionID = UUID().uuidString
		let micPath = tempDir.appendingPathComponent("hex_call_mic_\(sessionID).wav")

		// Recording format: 16kHz mono Float32
		let format = AVAudioFormat(
			commonFormat: .pcmFormatFloat32,
			sampleRate: 16000,
			channels: 1,
			interleaved: false
		)!

		// Set up mic engine
		let micEng = AVAudioEngine()
		if let micUID = micDeviceUID {
			try setInputDevice(engine: micEng, deviceUID: micUID)
		}
		// else uses system default

		let micInputNode = micEng.inputNode
		let micHardwareFormat = micInputNode.outputFormat(forBus: 0)
		logger.notice("Mic hardware format: \(micHardwareFormat)")

		let micAudioFile = try AVAudioFile(
			forWriting: micPath,
			settings: format.settings,
			commonFormat: .pcmFormatFloat32,
			interleaved: false
		)

		// Install tap on mic - convert from hardware format to our 16kHz mono format
		let micConverter = AVAudioConverter(from: micHardwareFormat, to: format)
		micInputNode.installTap(onBus: 0, bufferSize: 4096, format: micHardwareFormat) { [weak self] buffer, _ in
			guard let self else { return }
			if let converter = micConverter {
				let convertedBuffer = AVAudioPCMBuffer(
					pcmFormat: format,
					frameCapacity: AVAudioFrameCount(
						Double(buffer.frameLength) * format.sampleRate / micHardwareFormat.sampleRate
					)
				)!
				var error: NSError?
				var allConsumed = false
				converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
					if allConsumed {
						outStatus.pointee = .noDataNow
						return nil
					}
					allConsumed = true
					outStatus.pointee = .haveData
					return buffer
				}
				if error == nil, convertedBuffer.frameLength > 0 {
					try? micAudioFile.write(from: convertedBuffer)
					// Update meter
					let level = self.calculateLevel(buffer: convertedBuffer)
					self.meterContinuation?.yield(level)
				}
			} else {
				try? micAudioFile.write(from: buffer)
				let level = self.calculateLevel(buffer: buffer)
				self.meterContinuation?.yield(level)
			}
		}

		try micEng.start()

		self.micEngine = micEng
		self.micFile = micAudioFile
		self.micURL = micPath
		self._isRecording = true
		self.recordingStartTime = Date()

		logger.notice("Call recording started mic=\(micPath.lastPathComponent)")
	}

	func stopRecording() -> URL {
		guard _isRecording else {
			return micURL ?? URL(fileURLWithPath: "")
		}

		micEngine?.inputNode.removeTap(onBus: 0)
		micEngine?.stop()

		micFile = nil

		_isRecording = false
		let duration = currentDuration
		recordingStartTime = nil

		let mic = micURL ?? URL(fileURLWithPath: "")

		logger.notice("Call recording stopped duration=\(String(format: "%.1f", duration))s")

		micEngine = nil

		return mic
	}

	func getAudioInputDevices() -> [AudioInputDevice] {
		var propertyAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDevices,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var dataSize: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(
			AudioObjectID(kAudioObjectSystemObject),
			&propertyAddress,
			0, nil,
			&dataSize
		) == noErr else { return [] }

		let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
		var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
		guard AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&propertyAddress,
			0, nil,
			&dataSize,
			&deviceIDs
		) == noErr else { return [] }

		return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
			// Check if device has input channels
			var inputAddress = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyStreamConfiguration,
				mScope: kAudioDevicePropertyScopeInput,
				mElement: kAudioObjectPropertyElementMain
			)
			var inputSize: UInt32 = 0
			guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize) == noErr,
				  inputSize > 0 else { return nil }

			let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
			defer { bufferListPointer.deallocate() }
			guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPointer) == noErr else { return nil }

			let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
			let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
			guard inputChannels > 0 else { return nil }

			// Get UID
			var uidAddress = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyDeviceUID,
				mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain
			)
			var uid: CFString = "" as CFString
			var uidSize = UInt32(MemoryLayout<CFString>.size)
			guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }

			// Get name
			var nameAddress = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyDeviceNameCFString,
				mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain
			)
			var name: CFString = "" as CFString
			var nameSize = UInt32(MemoryLayout<CFString>.size)
			guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }

			return AudioInputDevice(id: uid as String, name: name as String)
		}
	}

	func observeMicLevel() -> AsyncStream<Meter> {
		AsyncStream { continuation in
			self.meterContinuation = continuation
			continuation.onTermination = { @Sendable _ in
				Task { [weak self] in
					await self?.clearMeterContinuation()
				}
			}
		}
	}

	func cleanup() {
		if _isRecording {
			_ = stopRecording()
		}
		meterContinuation?.finish()
		meterContinuation = nil
	}

	// MARK: - Private Helpers

	private func clearMeterContinuation() {
		meterContinuation = nil
	}

	private nonisolated func calculateLevel(buffer: AVAudioPCMBuffer) -> Meter {
		guard let channelData = buffer.floatChannelData else {
			return Meter(averagePower: 0, peakPower: 0)
		}
		let frames = Int(buffer.frameLength)
		guard frames > 0 else { return Meter(averagePower: 0, peakPower: 0) }

		var sum: Float = 0
		var peak: Float = 0
		let data = channelData[0]
		for i in 0..<frames {
			let abs = Swift.abs(data[i])
			sum += abs * abs
			if abs > peak { peak = abs }
		}
		let rms = sqrt(sum / Float(frames))
		// Convert to dB-like scale (0..1 range)
		let avgPower = Double(max(0, min(1, rms * 3)))
		let peakPower = Double(max(0, min(1, peak)))
		return Meter(averagePower: avgPower, peakPower: peakPower)
	}

	private func setInputDevice(engine: AVAudioEngine, deviceUID: String) throws {
		let inputNode = engine.inputNode
		guard let audioUnit = inputNode.audioUnit else {
			throw CallRecordingError.audioUnitUnavailable
		}

		// Find the device ID from the UID by scanning all devices
		let deviceID = try findDeviceID(forUID: deviceUID)

		// Set the device on the audio unit
		var mutableDeviceID = deviceID
		let setStatus = AudioUnitSetProperty(
			audioUnit,
			kAudioOutputUnitProperty_CurrentDevice,
			kAudioUnitScope_Global,
			0,
			&mutableDeviceID,
			UInt32(MemoryLayout<AudioDeviceID>.size)
		)
		guard setStatus == noErr else {
			throw CallRecordingError.failedToSetDevice(deviceUID, setStatus)
		}

		logger.notice("Set input device to \(deviceUID) (deviceID: \(deviceID))")
	}

	private func findDeviceID(forUID targetUID: String) throws -> AudioDeviceID {
		var propertyAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDevices,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		var dataSize: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(
			AudioObjectID(kAudioObjectSystemObject),
			&propertyAddress, 0, nil, &dataSize
		) == noErr else {
			throw CallRecordingError.deviceNotFound(targetUID)
		}

		let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
		var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
		guard AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&propertyAddress, 0, nil, &dataSize, &deviceIDs
		) == noErr else {
			throw CallRecordingError.deviceNotFound(targetUID)
		}

		for id in deviceIDs {
			var uidAddress = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyDeviceUID,
				mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain
			)
			var uid: CFString = "" as CFString
			var uidSize = UInt32(MemoryLayout<CFString>.size)
			if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
			   (uid as String) == targetUID {
				return id
			}
		}
		throw CallRecordingError.deviceNotFound(targetUID)
	}
}

// MARK: - Errors

enum CallRecordingError: LocalizedError {
	case audioUnitUnavailable
	case deviceNotFound(String)
	case failedToSetDevice(String, OSStatus)

	var errorDescription: String? {
		switch self {
		case .audioUnitUnavailable:
			return "Audio unit not available on the input node."
		case .deviceNotFound(let uid):
			return "Audio device not found: \(uid)"
		case .failedToSetDevice(let uid, let status):
			return "Failed to set audio device \(uid): OSStatus \(status)"
		}
	}
}
