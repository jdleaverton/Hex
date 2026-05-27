import Foundation

// MARK: - Call Transcript

/// A speaker-labeled, timestamped segment of a call transcript.
public struct CallSegment: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var speakerId: String
	public var speakerName: String?
	public var text: String
	public var startTime: TimeInterval
	public var endTime: TimeInterval
	public var confidence: Float

	public init(
		id: UUID = UUID(),
		speakerId: String,
		speakerName: String? = nil,
		text: String,
		startTime: TimeInterval,
		endTime: TimeInterval,
		confidence: Float = 1.0
	) {
		self.id = id
		self.speakerId = speakerId
		self.speakerName = speakerName
		self.text = text
		self.startTime = startTime
		self.endTime = endTime
		self.confidence = confidence
	}
}

/// Complete transcript of a recorded call with metadata.
public struct CallTranscript: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var title: String?
	public var summary: String?
	public var date: Date
	public var duration: TimeInterval
	public var participants: [String]
	public var tags: [String]
	public var segments: [CallSegment]
	/// Path to the raw mic audio file
	public var micAudioPath: URL?
	/// Path to the saved markdown transcript
	public var markdownPath: URL?
	/// Whether the Claude cleanup pass has been applied
	public var hasBeenCleaned: Bool

	public init(
		id: UUID = UUID(),
		title: String? = nil,
		summary: String? = nil,
		date: Date = Date(),
		duration: TimeInterval = 0,
		participants: [String] = [],
		tags: [String] = [],
		segments: [CallSegment] = [],
		micAudioPath: URL? = nil,
		markdownPath: URL? = nil,
		hasBeenCleaned: Bool = false
	) {
		self.id = id
		self.title = title
		self.summary = summary
		self.date = date
		self.duration = duration
		self.participants = participants
		self.tags = tags
		self.segments = segments
		self.micAudioPath = micAudioPath
		self.markdownPath = markdownPath
		self.hasBeenCleaned = hasBeenCleaned
	}
}

/// History of all recorded calls.
public struct CallHistory: Codable, Equatable, Sendable {
	public var calls: [CallTranscript] = []

	public init(calls: [CallTranscript] = []) {
		self.calls = calls
	}
}

// MARK: - Speaker Enrollment

/// A persisted speaker profile for cross-call identification.
public struct EnrolledSpeaker: Codable, Equatable, Identifiable, Sendable {
	public var id: String
	public var name: String
	public var embedding: [Float]
	public var isPermanent: Bool
	public var callCount: Int
	public var lastSeenDate: Date

	public init(
		id: String,
		name: String,
		embedding: [Float],
		isPermanent: Bool = false,
		callCount: Int = 1,
		lastSeenDate: Date = Date()
	) {
		self.id = id
		self.name = name
		self.embedding = embedding
		self.isPermanent = isPermanent
		self.callCount = callCount
		self.lastSeenDate = lastSeenDate
	}
}

/// Database of enrolled speakers persisted to disk.
public struct SpeakerDatabase: Codable, Equatable, Sendable {
	public var speakers: [EnrolledSpeaker] = []

	public init(speakers: [EnrolledSpeaker] = []) {
		self.speakers = speakers
	}
}

// MARK: - Processing State

/// Tracks progress through the post-call processing pipeline.
public enum CallProcessingStage: String, Codable, Equatable, Sendable {
	case transcribingMic
	case transcribingSystem
	case diarizing
	case mergingTimeline
	case cleaningUp
	case savingTranscript
	case complete
	case failed
}

// MARK: - Markdown Generation

extension CallTranscript {
	/// Generates a markdown representation of the transcript.
	public func toMarkdown() -> String {
		var md = "---\n"
		md += "title: \(title ?? "Untitled Call")\n"

		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		md += "date: \(formatter.string(from: date))\n"
		md += "duration: \(Int(duration))\n"

		if !participants.isEmpty {
			md += "participants: [\(participants.joined(separator: ", "))]\n"
		}
		if !tags.isEmpty {
			md += "tags: [\(tags.joined(separator: ", "))]\n"
		}
		md += "---\n\n"

		if let summary {
			md += "## Summary\n\n\(summary)\n\n"
		}

		md += "## Transcript\n\n"
		for segment in segments {
			let timestamp = formatTimestamp(segment.startTime)
			let speaker = segment.speakerName ?? segment.speakerId
			md += "**[\(timestamp)] \(speaker):** \(segment.text)\n\n"
		}

		return md
	}

	private func formatTimestamp(_ seconds: TimeInterval) -> String {
		let h = Int(seconds) / 3600
		let m = (Int(seconds) % 3600) / 60
		let s = Int(seconds) % 60
		if h > 0 {
			return String(format: "%d:%02d:%02d", h, m, s)
		}
		return String(format: "%02d:%02d", m, s)
	}
}
