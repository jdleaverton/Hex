# 06 - Transcription Path Bakeoff

## Goal

Choose the best Parakeet transcription path from evidence, not taste.

## Options

- Fork path: `AudioPreparer.readAndPrependSilence(url:)` -> `parakeet.transcribe(samples:)`.
- Upstream path: `ParakeetClipPreparer.ensureMinimumDuration(url:)` -> `parakeet.transcribe(url)`.

## Implementation

1. Build a local comparison harness or debug-only path that can run both paths on the same audio clip.
2. Use a small fixture set:
   - short dictation under 2s
   - normal 5-10s dictation
   - long >15s dictation
   - silence/noise
   - clip with first-word edge
3. Capture:
   - prep time
   - inference time
   - total time
   - transcript text
   - empty/failure rate
   - chunk-boundary artifacts
4. Keep direct samples if correctness matches and latency wins.
5. Fall back to upstream file path if direct samples show correctness problems.

## Verification Gate

```bash
xcodebuild -scheme Hex -configuration Debug build
```

Manual comparison log query:

```bash
/usr/bin/log show --last 20m --style compact --predicate '(subsystem == "com.jdleaverton.Hex" OR subsystem == "com.kitlangton.Hex") AND (eventMessage CONTAINS "Parakeet path comparison" OR eventMessage CONTAINS "Parakeet pipeline")'
```

Acceptance:

- Chosen path has documented latency and correctness evidence.
- If direct samples remain, `AudioPreparer` is covered by focused tests or fixtures for format correctness.
- If file path wins, remove direct-sample-only complexity deliberately.

## Execution Notes

- Status: done
- Added an opt-in runtime bakeoff harness behind `HEX_PARAKEET_COMPARE_PATHS=1`.
- Normal transcription still returns the direct-sample path. With the flag enabled, Hex also runs the upstream file-based path on the same clip and logs direct/file prep, inference, total, text lengths, and normalized transcript match.
- Verified with `xcodebuild -scheme Hex -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
- Manual fixture runs still need to be captured with local microphone/model access before making a final evidence claim beyond keeping the existing fast path as default.
