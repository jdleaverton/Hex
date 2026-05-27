# 01 - Single-Flight Loading

Status: done

## Goal

Ensure only one Parakeet load can run per variant, and make cold-load timing explicit.

## Scope

- `Hex/Clients/ParakeetClient.swift`
- `Hex/Clients/TranscriptionClient.swift`
- Tests if a lightweight injectable loader seam is practical

## Implementation

1. Add `loadTask` and `loadVariant` to `ParakeetClient`.
2. Make `ensureLoaded` return immediately when already loaded.
3. Make concurrent callers for the same variant await the existing task.
4. Decide variant-switch policy explicitly: cancel stale in-flight loads when the selected model changes.
5. Clear load state on success, failure, or cancellation.
6. Add logs for `loadStarted`, `loadJoined`, `loadCompleted`, and `loadFailed`.
7. Ensure warmup runs once per successful cold load, not once per caller.
8. Keep progress reporting deterministic for both the original caller and joined callers.

## Edge Cases

- Same variant load joined by recording prewarm and stop/transcribe.
- Variant switch while another variant is loading.
- Load failure followed by retry.
- Delete cache while load is in flight.

## Verification Gate

```bash
xcodebuild -scheme Hex -configuration Debug build
```

Manual log check:

```bash
/usr/bin/log show --last 10m --style compact --predicate '(subsystem == "com.jdleaverton.Hex" OR subsystem == "com.kitlangton.Hex") AND (eventMessage CONTAINS "Parakeet" OR eventMessage CONTAINS "Transcription request")'
```

Acceptance:

- One cold recording produces exactly one `Starting Parakeet load`.
- If stop happens while prewarm is still loading, transcribe logs that it joined/waited rather than starting a new load.
- A failed load can be retried without stale `loadTask` state.

## Completion Notes

- Added per-variant single-flight load state to `ParakeetClient`.
- Concurrent same-variant callers now join the in-flight load; different-variant loads cancel stale work before starting.
- Warmup moved inside the successful cold-load task so it runs once per actual load.
- Load state clears after success, failure, cancellation, unload, and cache deletion.
- Verification passed: `xcodebuild -scheme Hex -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
- Plain `xcodebuild -scheme Hex -configuration Debug build` was blocked locally by package macro approval, then by a missing Mac Development signing certificate for team `QC99C9JE59`.
