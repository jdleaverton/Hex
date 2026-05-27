# 05 - Upstream Capture

## Goal

Port/adapt upstream's warm capture architecture without entangling it with Parakeet model loading.

## Source References

- `origin/main:Hex/Clients/SuperFastCaptureController.swift`
- `origin/main:Hex/Clients/RecordingClient.swift`
- upstream commits:
  - `c5d5162` `Keep the microphone warm for faster recording starts`
  - `53b4d40` `Recover warm capture after wake and route changes`
  - `3e325fc` `Reduce super fast buffer carryover between recordings`
  - `d9e40cc` `Stabilize capture startup and microphone selection`
  - `55249a6` `Prevent clipped endings in super fast recordings`

## Implementation

1. Compare current dirty `RecordingClient.swift` against `origin/main` and identify conflicts with local keep-alive/device-change work.
2. Port `SuperFastCaptureController` or adapt its core ideas:
   - warm `AVAudioEngine`
   - 16 kHz mono Float32 conversion
   - 1.0s ring buffer
   - 0.45s pre-roll
   - callback-based stop grace timing
   - configuration/route-change recovery
3. Preserve current selected-mic pinning behavior unless upstream demonstrably improves it.
4. Add/keep a setting only if already required by local settings migration; otherwise default warm capture on.
5. Ensure capture readiness does not trigger model load and model readiness does not block capture.

## Risks

- Current worktree already has uncommitted `RecordingClient.swift` edits. Execution must merge carefully.
- Audio engine warm mode can conflict with sleep, TCC, or device-route changes.
- Pre-roll can duplicate audio if buffers are not cleared between recordings.

## Verification Gate

```bash
xcodebuild -scheme Hex -configuration Debug build
```

Focused runtime QA:

1. Start Hex.
2. Record a very short first clip.
3. Confirm first syllable is captured.
4. Change input device or wake from sleep if practical.
5. Record again and confirm capture recovers.

Log query:

```bash
/usr/bin/log show --last 20m --style compact --predicate '(subsystem == "com.jdleaverton.Hex" OR subsystem == "com.kitlangton.Hex") AND (category == "Recording" OR eventMessage CONTAINS "Capture engine")'
```

Acceptance:

- First capture starts immediately.
- No clipped first word on quick recordings.
- Route changes recover without requiring app restart.
- Capture logs are concise and operator-readable.

## Execution Notes

- Status: done
- Added upstream `SuperFastCaptureController` as an independent warm capture layer.
- `RecordingClient` now tries `capture=superFast` first with AVAudioRecorder fallback, preserving selected-mic pinning, media control, and the existing device guardian.
- Warmup arms the capture engine with a warm pre-roll buffer and does not touch Parakeet model loading.
- Configuration changes stop/rearm the capture engine when idle and defer recovery during an active recording.
- Verified with `xcodebuild -scheme Hex -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
- Runtime mic QA/log query still needs a local interactive run with microphone permission.
