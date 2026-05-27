# 04 - Inference Queue

## Goal

Prevent concurrent Parakeet inference crashes without silently returning empty transcripts.

## Scope

- `Hex/Clients/ParakeetClient.swift`
- `Hex/Features/CallRecording/CallRecordingFeature.swift` if normal dictation and call recording can overlap

## Implementation

1. Replace `guard !isTranscribing else { return "" }` with explicit serialization.
2. Decide policy:
   - Preferred: queue second inference and log `queuedMs`.
   - Alternative: throw a structured busy error that UI can surface.
3. For call recording, sequence mic and system tracks deliberately or use a separate ASR instance if memory allows.
4. Add lifecycle timing for queued wait versus inference time.
5. Keep this at the Parakeet client boundary so every feature shares the same safety contract.

## Verification Gate

```bash
cd HexCore && swift test
xcodebuild test -scheme Hex
```

If `xcodebuild test` is too broad or requires unavailable signing, record the exact failure and run the narrowest compiling target instead.

Acceptance:

- No path can produce an empty transcript solely because Parakeet was busy.
- Concurrent call-recording and dictation behavior is deterministic.
- Logs separate model load wait, inference queue wait, and actual inference time.

## Execution Notes

- Status: done
- Replaced busy-path empty transcript returns with actor-local queueing in `ParakeetClient`.
- Queue waits now log `queuedMs` separately from `inferenceMs` for file and direct-sample paths.
- Verified `cd HexCore && swift test` with 76 tests passing.
- `xcodebuild test -scheme Hex -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO` is blocked by scheme configuration: `Could not find test host for HexTests`; `TEST_HOST` points to `Hex.app` while this scheme builds `Hex Debug.app`.
- Verified compile after the queue patch with `xcodebuild -scheme Hex -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
