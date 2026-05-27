import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let logger = HexLog.callCleanup

// MARK: - Cleanup Result

struct CleanupResult: Equatable, Sendable {
	var title: String
	var summary: String
	var participants: [String]
	var tags: [String]
	var cleanedSegments: [CallSegment]
}

// MARK: - Client Interface

@DependencyClient
struct CallCleanupClient {
	/// Run Claude API cleanup on a raw transcript
	var cleanup: @Sendable (_ segments: [CallSegment], _ context: String?) async throws -> CleanupResult = { _, _ in
		CleanupResult(title: "", summary: "", participants: [], tags: [], cleanedSegments: [])
	}
}

extension CallCleanupClient: DependencyKey {
	static var liveValue: Self {
		Self(
			cleanup: { segments, context in
				try await performCleanup(segments: segments, context: context)
			}
		)
	}
}

extension DependencyValues {
	var callCleanup: CallCleanupClient {
		get { self[CallCleanupClient.self] }
		set { self[CallCleanupClient.self] = newValue }
	}
}

// MARK: - Implementation

private func performCleanup(segments: [CallSegment], context: String?) async throws -> CleanupResult {
	let t0 = Date()
	logger.notice("Starting Claude cleanup for \(segments.count) segments")

	// Build the raw transcript text for the prompt
	var transcriptText = ""
	for seg in segments {
		let timestamp = formatTimestamp(seg.startTime)
		let speaker = seg.speakerName ?? seg.speakerId
		transcriptText += "[\(timestamp)] \(speaker): \(seg.text)\n"
	}

	let contextLine = context.map { "\nContext about this call: \($0)\n" } ?? ""

	let prompt = """
	You are a transcript editor. Given a raw call transcript with speaker labels and timestamps, \
	clean it up and return a JSON response.

	Tasks:
	1. Fix obvious transcription errors and jargon based on conversation context
	2. Infer real speaker names from context clues (e.g., "Alice, can you update us?" → next speaker is Alice)
	3. Generate a concise title for the call
	4. Write a 2-3 sentence summary
	5. Suggest relevant tags
	6. List participant names
	\(contextLine)
	Raw transcript:
	\(transcriptText)

	Respond with ONLY valid JSON in this exact format:
	{
	  "title": "string",
	  "summary": "string",
	  "participants": ["string"],
	  "tags": ["string"],
	  "segments": [
	    {
	      "speakerId": "string (original ID)",
	      "speakerName": "string (inferred or original name)",
	      "text": "string (cleaned text)",
	      "startTime": number,
	      "endTime": number
	    }
	  ]
	}
	"""

	// Make API call using URLSession
	guard let apiKey = getAnthropicAPIKey() else {
		logger.warning("No Anthropic API key found — skipping cleanup")
		throw CleanupError.noAPIKey
	}

	let requestBody: [String: Any] = [
		"model": "claude-sonnet-4-20250514",
		"max_tokens": 8192,
		"messages": [
			["role": "user", "content": prompt]
		]
	]

	let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

	var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
	request.httpMethod = "POST"
	request.setValue("application/json", forHTTPHeaderField: "content-type")
	request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
	request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
	request.httpBody = jsonData

	let (data, response) = try await URLSession.shared.data(for: request)

	guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
		let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
		logger.error("Claude API returned status \(statusCode)")
		throw CleanupError.apiError(statusCode)
	}

	// Parse the Claude response
	guard let responseJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		  let content = responseJSON["content"] as? [[String: Any]],
		  let firstBlock = content.first,
		  let text = firstBlock["text"] as? String else {
		throw CleanupError.invalidResponse
	}

	// Extract JSON from the response text (handle markdown code blocks)
	let jsonText = extractJSON(from: text)

	guard let cleanedData = jsonText.data(using: .utf8),
		  let cleaned = try JSONSerialization.jsonObject(with: cleanedData) as? [String: Any] else {
		throw CleanupError.invalidJSON
	}

	let title = cleaned["title"] as? String ?? "Untitled Call"
	let summary = cleaned["summary"] as? String ?? ""
	let participants = cleaned["participants"] as? [String] ?? []
	let tags = cleaned["tags"] as? [String] ?? []

	var cleanedSegments: [CallSegment] = []
	if let segs = cleaned["segments"] as? [[String: Any]] {
		for seg in segs {
			cleanedSegments.append(CallSegment(
				speakerId: seg["speakerId"] as? String ?? "unknown",
				speakerName: seg["speakerName"] as? String,
				text: seg["text"] as? String ?? "",
				startTime: seg["startTime"] as? TimeInterval ?? 0,
				endTime: seg["endTime"] as? TimeInterval ?? 0
			))
		}
	}

	// If no segments were returned, use originals
	if cleanedSegments.isEmpty {
		cleanedSegments = segments
	}

	let elapsed = Date().timeIntervalSince(t0)
	logger.notice("Claude cleanup complete in \(String(format: "%.1f", elapsed))s — title: '\(title)', \(participants.count) participants")

	return CleanupResult(
		title: title,
		summary: summary,
		participants: participants,
		tags: tags,
		cleanedSegments: cleanedSegments
	)
}

// MARK: - Helpers

private func getAnthropicAPIKey() -> String? {
	// Check environment variable first
	if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
		return key
	}
	// Check Keychain
	let query: [String: Any] = [
		kSecClass as String: kSecClassGenericPassword,
		kSecAttrService as String: "com.jdleaverton.Hex.anthropic",
		kSecAttrAccount as String: "api_key",
		kSecReturnData as String: true,
		kSecMatchLimit as String: kSecMatchLimitOne
	]
	var result: AnyObject?
	if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
	   let data = result as? Data,
	   let key = String(data: data, encoding: .utf8) {
		return key
	}
	return nil
}

private func extractJSON(from text: String) -> String {
	// Try to extract JSON from markdown code blocks
	if let jsonStart = text.range(of: "```json\n"),
	   let jsonEnd = text.range(of: "\n```", range: jsonStart.upperBound..<text.endIndex) {
		return String(text[jsonStart.upperBound..<jsonEnd.lowerBound])
	}
	if let jsonStart = text.range(of: "```\n"),
	   let jsonEnd = text.range(of: "\n```", range: jsonStart.upperBound..<text.endIndex) {
		return String(text[jsonStart.upperBound..<jsonEnd.lowerBound])
	}
	// Try to find JSON object directly
	if let start = text.firstIndex(of: "{"),
	   let end = text.lastIndex(of: "}") {
		return String(text[start...end])
	}
	return text
}

private func formatTimestamp(_ seconds: TimeInterval) -> String {
	let m = Int(seconds) / 60
	let s = Int(seconds) % 60
	return String(format: "%02d:%02d", m, s)
}

enum CleanupError: LocalizedError {
	case noAPIKey
	case apiError(Int)
	case invalidResponse
	case invalidJSON

	var errorDescription: String? {
		switch self {
		case .noAPIKey:
			return "No Anthropic API key found. Set ANTHROPIC_API_KEY environment variable or store in Keychain."
		case .apiError(let code):
			return "Claude API error: HTTP \(code)"
		case .invalidResponse:
			return "Invalid response from Claude API"
		case .invalidJSON:
			return "Could not parse JSON from Claude response"
		}
	}
}
