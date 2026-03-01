import AVFoundation
import Foundation
import HexCore

/// Prepares audio for transcription by prepending silence.
/// Prepending silence ensures ML models don't clip the first spoken word,
/// especially when recording started with slight latency under CPU stress.
enum AudioPreparer {
  private static let logger = HexLog.transcription

  /// Default silence to prepend (seconds). Gives the model a clean "start of speech" boundary.
  static let defaultSilenceDuration: TimeInterval = 0.3

  /// Parakeet/FluidAudio's native sample rate.
  static let sampleRate: Double = 16000.0

  private enum Error: LocalizedError {
    case unsupportedFormat
    case bufferAllocationFailed
    case audioFileTooShort

    var errorDescription: String? {
      switch self {
      case .unsupportedFormat:
        return "AudioPreparer requires Float32 PCM audio."
      case .bufferAllocationFailed:
        return "Unable to allocate audio buffer."
      case .audioFileTooShort:
        return "Audio file contains no samples."
      }
    }
  }

  // MARK: - Buffer-based (for Parakeet direct sample path)

  /// Reads an audio file into a Float32 sample array and prepends silence.
  /// Returns raw 16 kHz mono samples ready for FluidAudio's `asr.transcribe(_ samples:)`.
  /// FluidAudio's AudioConverter handles resampling internally, so we read at the
  /// file's native format and let FluidAudio resample. However, since our recordings
  /// are already 16 kHz mono Float32, this is effectively a no-op copy.
  static func readAndPrependSilence(
    url: URL,
    silenceDuration: TimeInterval = defaultSilenceDuration
  ) throws -> [Float] {
    let audioFile = try AVAudioFile(forReading: url)
    let format = audioFile.processingFormat
    let existingFrames = AVAudioFrameCount(max(0, audioFile.length))

    guard existingFrames > 0 else {
      throw Error.audioFileTooShort
    }
    guard format.commonFormat == .pcmFormatFloat32 else {
      throw Error.unsupportedFormat
    }

    guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: existingFrames) else {
      throw Error.bufferAllocationFailed
    }
    try audioFile.read(into: readBuffer)

    guard let channelData = readBuffer.floatChannelData else {
      throw Error.unsupportedFormat
    }

    let frameCount = Int(readBuffer.frameLength)
    let silenceFrames = Int((silenceDuration * format.sampleRate).rounded(.up))

    // Build [silence + audio] in one contiguous array
    var samples = [Float](repeating: 0, count: silenceFrames + frameCount)
    // Copy channel 0 (mono) after the silence prefix
    samples.withUnsafeMutableBufferPointer { dst in
      let src = UnsafeBufferPointer(start: channelData[0], count: frameCount)
      _ = dst.baseAddress!.advanced(by: silenceFrames).update(from: src.baseAddress!, count: frameCount)
    }

    logger.debug(
      "Read \(url.lastPathComponent) (\(frameCount) frames) + \(silenceFrames) silence frames → \(samples.count) total"
    )

    return samples
  }

  // MARK: - File-based (for WhisperKit which takes a file path)

  /// Prepends silence to the beginning of an audio file on disk.
  /// Returns the original URL if silenceDuration is 0.
  static func prependSilence(
    url: URL,
    silenceDuration: TimeInterval = defaultSilenceDuration
  ) throws -> ParakeetClipPreparationResult {
    guard silenceDuration > 0 else {
      return ParakeetClipPreparationResult(url: url, cleanupURL: nil)
    }

    let audioFile = try AVAudioFile(forReading: url)
    let format = audioFile.processingFormat

    guard format.commonFormat == .pcmFormatFloat32 else {
      throw Error.unsupportedFormat
    }

    let existingFrames = AVAudioFrameCount(max(0, audioFile.length))
    guard existingFrames > 0 else {
      throw Error.audioFileTooShort
    }

    let silenceFrames = AVAudioFrameCount((silenceDuration * format.sampleRate).rounded(.up))
    let totalFrames = silenceFrames + existingFrames

    guard
      let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: existingFrames),
      let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)
    else {
      throw Error.bufferAllocationFailed
    }

    try audioFile.read(into: readBuffer)

    guard
      let srcChannels = readBuffer.floatChannelData,
      let dstChannels = outputBuffer.floatChannelData
    else {
      throw Error.unsupportedFormat
    }

    let channelCount = Int(format.channelCount)
    for ch in 0..<channelCount {
      dstChannels[ch].initialize(repeating: 0, count: Int(silenceFrames))
      dstChannels[ch].advanced(by: Int(silenceFrames))
        .update(from: srcChannels[ch], count: Int(readBuffer.frameLength))
    }
    outputBuffer.frameLength = totalFrames

    let paddedURL = url.deletingLastPathComponent()
      .appendingPathComponent(
        "\(url.deletingPathExtension().lastPathComponent)-prepadded.wav"
      )

    if FileManager.default.fileExists(atPath: paddedURL.path) {
      try FileManager.default.removeItem(at: paddedURL)
    }

    let paddedFile = try AVAudioFile(forWriting: paddedURL, settings: audioFile.fileFormat.settings)
    try paddedFile.write(from: outputBuffer)

    logger.debug(
      "Prepended \(String(format: "%.2f", silenceDuration))s silence → \(paddedURL.lastPathComponent)"
    )

    return ParakeetClipPreparationResult(url: paddedURL, cleanupURL: paddedURL)
  }
}
