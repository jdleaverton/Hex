import XCTest
@testable import HexCore

final class CallRecordingTests: XCTestCase {
	// MARK: - CallTranscript Serialization

	func testCallTranscriptEncodeDecodeRoundTrip() throws {
		let segment = CallSegment(
			speakerId: "speaker_1",
			speakerName: "Alice",
			text: "Hello, can you hear me?",
			startTime: 5.0,
			endTime: 8.5,
			confidence: 0.95
		)

		let transcript = CallTranscript(
			title: "Test Call",
			summary: "A test call about authentication.",
			date: Date(timeIntervalSince1970: 1711468800), // Fixed date
			duration: 300,
			participants: ["Alice", "Bob"],
			tags: ["test", "auth"],
			segments: [segment],
			hasBeenCleaned: true
		)

		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		let data = try encoder.encode(transcript)

		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let decoded = try decoder.decode(CallTranscript.self, from: data)

		XCTAssertEqual(decoded.title, "Test Call")
		XCTAssertEqual(decoded.summary, "A test call about authentication.")
		XCTAssertEqual(decoded.duration, 300)
		XCTAssertEqual(decoded.participants, ["Alice", "Bob"])
		XCTAssertEqual(decoded.tags, ["test", "auth"])
		XCTAssertEqual(decoded.segments.count, 1)
		XCTAssertEqual(decoded.segments[0].speakerId, "speaker_1")
		XCTAssertEqual(decoded.segments[0].speakerName, "Alice")
		XCTAssertEqual(decoded.segments[0].text, "Hello, can you hear me?")
		XCTAssertEqual(decoded.segments[0].startTime, 5.0)
		XCTAssertEqual(decoded.segments[0].endTime, 8.5)
		XCTAssertEqual(decoded.segments[0].confidence, 0.95)
		XCTAssertTrue(decoded.hasBeenCleaned)
	}

	func testCallTranscriptDefaultValues() {
		let transcript = CallTranscript()
		XCTAssertNil(transcript.title)
		XCTAssertNil(transcript.summary)
		XCTAssertEqual(transcript.duration, 0)
		XCTAssertEqual(transcript.participants, [])
		XCTAssertEqual(transcript.tags, [])
		XCTAssertEqual(transcript.segments, [])
		XCTAssertFalse(transcript.hasBeenCleaned)
		XCTAssertNil(transcript.micAudioPath)
		XCTAssertNil(transcript.markdownPath)
	}

	// MARK: - Markdown Generation

	func testMarkdownGeneration() {
		let transcript = CallTranscript(
			title: "Standup with Engineering",
			summary: "Discussed auth migration timeline.",
			date: Date(timeIntervalSince1970: 1711468800),
			duration: 1847,
			participants: ["JD", "Alice", "Bob"],
			tags: ["standup", "engineering"],
			segments: [
				CallSegment(
					speakerId: "mic",
					speakerName: "JD",
					text: "Alright, let's get started.",
					startTime: 5,
					endTime: 8
				),
				CallSegment(
					speakerId: "speaker_1",
					speakerName: "Alice",
					text: "Sure, I've been looking at the auth code.",
					startTime: 8,
					endTime: 12
				),
			]
		)

		let md = transcript.toMarkdown()
		XCTAssert(md.contains("title: Standup with Engineering"))
		XCTAssert(md.contains("duration: 1847"))
		XCTAssert(md.contains("participants: [JD, Alice, Bob]"))
		XCTAssert(md.contains("tags: [standup, engineering]"))
		XCTAssert(md.contains("## Summary"))
		XCTAssert(md.contains("Discussed auth migration timeline."))
		XCTAssert(md.contains("## Transcript"))
		XCTAssert(md.contains("**[00:05] JD:** Alright, let's get started."))
		XCTAssert(md.contains("**[00:08] Alice:** Sure, I've been looking at the auth code."))
	}

	func testMarkdownTimestampFormattingWithHours() {
		let transcript = CallTranscript(
			title: "Long Call",
			duration: 7200,
			segments: [
				CallSegment(
					speakerId: "mic",
					speakerName: "JD",
					text: "Still going.",
					startTime: 3661, // 1:01:01
					endTime: 3665
				),
			]
		)

		let md = transcript.toMarkdown()
		XCTAssert(md.contains("[1:01:01]"))
	}

	// MARK: - EnrolledSpeaker Serialization

	func testEnrolledSpeakerEncodeDecodeRoundTrip() throws {
		let speaker = EnrolledSpeaker(
			id: "spk_001",
			name: "Alice",
			embedding: [0.1, 0.2, 0.3, 0.4],
			isPermanent: true,
			callCount: 5,
			lastSeenDate: Date(timeIntervalSince1970: 1711468800)
		)

		let data = try JSONEncoder().encode(speaker)
		let decoded = try JSONDecoder().decode(EnrolledSpeaker.self, from: data)

		XCTAssertEqual(decoded.id, "spk_001")
		XCTAssertEqual(decoded.name, "Alice")
		XCTAssertEqual(decoded.embedding, [0.1, 0.2, 0.3, 0.4])
		XCTAssertTrue(decoded.isPermanent)
		XCTAssertEqual(decoded.callCount, 5)
	}

	// MARK: - SpeakerDatabase

	func testSpeakerDatabaseEncodeDecodeRoundTrip() throws {
		let db = SpeakerDatabase(speakers: [
			EnrolledSpeaker(id: "1", name: "Alice", embedding: [0.1, 0.2]),
			EnrolledSpeaker(id: "2", name: "Bob", embedding: [0.3, 0.4]),
		])

		let data = try JSONEncoder().encode(db)
		let decoded = try JSONDecoder().decode(SpeakerDatabase.self, from: data)

		XCTAssertEqual(decoded.speakers.count, 2)
		XCTAssertEqual(decoded.speakers[0].name, "Alice")
		XCTAssertEqual(decoded.speakers[1].name, "Bob")
	}

	// MARK: - CallHistory

	func testCallHistoryEncodeDecodeRoundTrip() throws {
		let history = CallHistory(calls: [
			CallTranscript(title: "Call 1", duration: 100),
			CallTranscript(title: "Call 2", duration: 200),
		])

		let data = try JSONEncoder().encode(history)
		let decoded = try JSONDecoder().decode(CallHistory.self, from: data)

		XCTAssertEqual(decoded.calls.count, 2)
		XCTAssertEqual(decoded.calls[0].title, "Call 1")
		XCTAssertEqual(decoded.calls[1].title, "Call 2")
	}

	// MARK: - HexSettings Backward Compatibility

	func testExistingSettingsDecodeWithNewCallRecordingDefaults() throws {
		// Simulate a settings JSON that was saved BEFORE call recording was added
		// All call recording fields should get their defaults
		let legacyJSON = """
		{
			"soundEffectsEnabled": true,
			"selectedModel": "parakeet-tdt-0.6b-v3-coreml"
		}
		"""
		let data = legacyJSON.data(using: .utf8)!
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		// New call recording fields should have defaults
		XCTAssertFalse(decoded.callRecordingEnabled)
		XCTAssertNil(decoded.callRecordingStoragePath)
		XCTAssertFalse(decoded.callRecordingAutoCommit)
		XCTAssertFalse(decoded.callRecordingClaudeCleanup)
		XCTAssertEqual(decoded.callRecordingUserName, "Me")

		// Existing fields should be preserved
		XCTAssertTrue(decoded.soundEffectsEnabled)
		XCTAssertEqual(decoded.selectedModel, "parakeet-tdt-0.6b-v3-coreml")
	}

	func testCallRecordingSettingsRoundTrip() throws {
		var settings = HexSettings()
		settings.callRecordingEnabled = true
		settings.callRecordingStoragePath = "/Users/test/CallBank"
		settings.callRecordingAutoCommit = true
		settings.callRecordingClaudeCleanup = true
		settings.callRecordingUserName = "JD"

		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		XCTAssertTrue(decoded.callRecordingEnabled)
		XCTAssertEqual(decoded.callRecordingStoragePath, "/Users/test/CallBank")
		XCTAssertTrue(decoded.callRecordingAutoCommit)
		XCTAssertTrue(decoded.callRecordingClaudeCleanup)
		XCTAssertEqual(decoded.callRecordingUserName, "JD")
	}
}
