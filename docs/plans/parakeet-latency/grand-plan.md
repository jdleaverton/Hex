# Instant Dictation Grand Plan

## Status

- Status: completed
- Owner: unassigned
- Source evidence date: 2026-05-27
- Scope: Hex macOS app only
- Plan folder: `docs/plans/parakeet-latency/`
- Dirty-tree boundary: current worktree has unrelated/uncommitted call-recording, settings, app icon, recording, and logging changes. Execution agents must preserve those changes and avoid broad rewrites.

## Goal

Make Hex feel instant and reliable by combining the best parts of the fork and upstream:

- Upstream's warm capture architecture for first-word capture and recorder startup.
- Upstream's session-warm Parakeet policy, which avoids the bad 5 minute idle unload tradeoff.
- The fork's fast direct-sample Parakeet path, timing logs, and ANE/warmup ideas where measurements justify them.
- New hardening neither side fully has: single-flight model loading, deterministic inference serialization, model-readiness UI, and verification gates.

## Evidence Summary

Runtime logs show Parakeet inference is fast once loaded:

- Warm path: `ensureLoaded: 0ms`, total `80-189ms` for normal short clips.
- Slow path: total `28480ms`, `30290ms`, and `33638ms`, dominated by cold `ensureLoaded`.
- Slow paths occur after `Idle timeout reached - unloading model to reclaim memory`.
- Duplicate `Starting Parakeet load` lines show prewarm and stop/transcribe can both enter `ensureLoaded` before the first load finishes.

Measured cost of keeping Parakeet loaded on this machine:

- RSS delta: about `+30.0 MiB`.
- `vmmap` physical-footprint delta: about `+19.1 MiB`.
- Idle CPU: `0.0%` both loaded and unloaded.
- Disk cache: already paid once downloaded, `443M` per FluidAudio model cache root plus `17M` e5rt compiled cache in the active container.

Conclusion: reclaiming ~20-30 MiB is not worth reintroducing 28-33s surprise latency in a dictation app.

## Upstream/Fork Architecture Read

### Upstream Wins

- `origin/main` removed the 5 minute model unload behavior. Once Parakeet is loaded, it stays loaded until app exit/model switch/delete.
- `origin/main` added `SuperFastCaptureController`, a warm `AVAudioEngine` capture path with ring-buffer pre-roll, stop grace timing, and route-change recovery.
- Upstream separated capture latency from model latency. This is architecturally correct.

### Fork Wins

- Direct-sample Parakeet path is measured extremely fast when loaded.
- Existing lifecycle logs expose useful timing splits: load, audio prep, inference, total, finalize.
- ANE warmup may help, though its current 1s silent input should be validated against FluidAudio's 15s/240000-sample graph constraints.

### Neither Side Fully Solves

- Single-flight Parakeet loading under Swift actor reentrancy.
- Inference serialization without silent data loss.
- Explicit model lifecycle state in TCA.
- UI that distinguishes "preparing model" from "transcribing".
- A repeatable cold/warm/capture validation harness.

## Product Experience Map

### Warm Normal Dictation

1. User presses hotkey.
2. Capture begins immediately, with pre-roll available if warm capture is enabled.
3. User releases hotkey.
4. Parakeet is already loaded.
5. Audio prep + inference complete in under 500ms for short clips.
6. Text is pasted and optional history is stored.

Target: feels instant; no visible "preparing" state.

### Cold First Dictation

1. User presses hotkey before startup prewarm is done.
2. Capture still begins immediately.
3. Model load runs once.
4. If user stops before load finishes, UI shows a compact preparing-model state.
5. Once loaded, inference runs and paste completes.

Target: no mystery hang; exactly one model load.

### Idle Break

1. User pauses for 5, 30, or 60 minutes.
2. Parakeet remains loaded by default.
3. Next dictation stays warm.

Target: no idle surprise. Optional memory-pressure unload can be added later only with measured evidence.

### Model Switch/Delete

1. User switches selected model or deletes cached model.
2. Current loaded model is released deliberately.
3. New selected model prewarms in background if downloaded.
4. UI/status reflects model readiness.

Target: explicit lifecycle transition, not hidden cold load.

### Call Recording / Concurrent Work

1. Call recording may transcribe mic and system tracks.
2. Normal dictation may also be triggered.
3. Parakeet inference must be queued or explicitly rejected; it must not return an empty transcript.

Target: deterministic behavior with logs that show queue wait separately from inference.

## Technical Architecture

### Layer 1: Capture

Adopt upstream's warm capture architecture as a separate layer:

- Keep a warm `AVAudioEngine` for the selected mic.
- Maintain a bounded Float32 ring buffer.
- Prepend a small pre-roll so first syllables are not clipped.
- Recover from route/configuration changes.
- Keep capture startup independent from model loading.

### Layer 2: Model Lifecycle

Use a session-warm selected-model policy:

- Keep selected Parakeet loaded by default.
- Remove the 300s idle unload.
- Unload on model switch, model deletion, app exit, and optional future memory pressure.
- Start background prewarm after app task when selected model is downloaded.
- Add single-flight loading so all load callers await the same in-flight task.

### Layer 3: Inference

Keep the direct-sample Parakeet path if validation confirms it is correct:

- Ensure samples are known-good 16 kHz mono Float32.
- Keep timings for audio prep and inference.
- Compare direct-sample vs upstream file-based path with identical clips before changing it.
- Serialize `AsrManager` inference; never return empty text because the model is busy.

### Layer 4: UI/State

Add explicit model lifecycle state:

- `notDownloaded`
- `unloaded`
- `loading(progress, startedAt)`
- `loaded`
- `failed(error)`

Surface compact states:

- recording
- recording + preparing
- preparing model
- transcribing
- error

No verbose in-app explanations. The UI should feel like status, not documentation.

### Layer 5: Observability

One concise lifecycle line per transcription:

`Transcription request model=<id> modelState=<warm|cold|joiningLoad> capture=<standard|superFast> audio=<seconds>s loadWait=<ms> prepare=<ms> queue=<ms> inference=<ms> finalize=<ms> total=<ms>`

Model lifecycle logs:

- load started
- joined existing load
- load completed
- load failed
- unload reason
- startup prewarm skipped/started/completed

## In Scope

- `Hex/Clients/TranscriptionClient.swift`
- `Hex/Clients/ParakeetClient.swift`
- `Hex/Clients/AudioPreparer.swift`
- `Hex/Clients/ParakeetClipPreparer.swift`
- `Hex/Clients/RecordingClient.swift`
- `Hex/Clients/SuperFastCaptureController.swift` from upstream, if ported
- `Hex/Features/Transcription/*`
- `Hex/Features/App/AppFeature.swift`
- `HexCore/Sources/HexCore/Settings/HexSettings.swift` if settings need migration
- `HexCore/Sources/HexCore/StoragePaths.swift` if upstream cache-path decisions are adopted
- focused tests under `HexCore/Tests` and/or `HexTests`
- `.changeset/*.md`

## Out Of Scope

- Releasing/notarizing/uploading a new version.
- Call-recording feature design beyond making Parakeet concurrency safe.
- Updating FluidAudio to current upstream API unless a focused spike proves it is needed.
- Full merge of all `origin/main` changes. This plan cherry-picks architecture decisions.

## Verification Matrix

| Chunk | Change Categories | Required Gates | Server Needed? |
|---|---|---|---|
| 01 | service concurrency, model lifecycle, logging | `xcodebuild -scheme Hex -configuration Debug build`; focused unit tests if loader seam added | No |
| 02 | lifecycle policy, app startup, settings if needed | `xcodebuild -scheme Hex -configuration Debug build`; unified-log cold/warm smoke | No |
| 03 | TCA state, SwiftUI indicator | `xcodebuild -scheme Hex -configuration Debug build`; manual cold/warm UI QA | No |
| 04 | inference serialization, call-recording interaction | `cd HexCore && swift test`; `xcodebuild test -scheme Hex` if available | No |
| 05 | upstream capture port, recording engine | `xcodebuild -scheme Hex -configuration Debug build`; recording runtime smoke; focused recording tests | No |
| 06 | direct-sample vs file-path comparison | `xcodebuild -scheme Hex -configuration Debug build`; local log/fixture comparison | No |
| 07 | release hygiene and final validation | `bun run changeset:status`; `xcodebuild -scheme Hex -configuration Release build` | No |

## Chunk Tracker

| Chunk | Status | Goal |
|---|---|---|
| [01-single-flight-loading](chunks/01-single-flight-loading.md) | done | Stop duplicate Parakeet loads and make model lifecycle logs precise. |
| [02-warmth-policy](chunks/02-warmth-policy.md) | done | Match upstream's session-warm Parakeet policy and prewarm selected downloaded models. |
| [03-user-visible-readiness](chunks/03-user-visible-readiness.md) | done | Make cold starts legible without UI clutter. |
| [04-inference-queue](chunks/04-inference-queue.md) | done | Prevent concurrent Parakeet inference crashes or silent empty transcripts. |
| [05-upstream-capture](chunks/05-upstream-capture.md) | done | Port/adapt upstream warm capture architecture as a separate layer. |
| [06-transcription-path-bakeoff](chunks/06-transcription-path-bakeoff.md) | done | Validate direct-sample vs upstream file-based Parakeet paths and choose deliberately. |
| [07-validation-release](chunks/07-validation-release.md) | done | Prove latency, capture, correctness, and release hygiene. |

## Proposed Detectors

- `parakeet_load_singleflight_check`: a unit or integration seam that triggers concurrent `ensureLoaded` calls and asserts only one underlying load starts.
- `parakeet_busy_no_empty_transcript_check`: a test that triggers overlapping transcriptions and asserts the second request queues or fails explicitly, never returning `""` due to contention.
- `transcription_latency_log_check`: a script or test helper that scans recent unified logs for required lifecycle fields after manual QA.

## Open Questions

- Should startup prewarm happen immediately on app task or after a short delay to avoid login launch noise?
- Should model readiness be Parakeet-only first, or generalized to WhisperKit?
- Should call recording use the same serialized `AsrManager`, or a separate manager when memory allows?
- Does 1s silent ANE warmup materially help compared with no warmup or a near-15s silent warmup?

## Runtime Acceptance

After implementation:

- Launch Hex with downloaded Parakeet selected; background readiness should complete without foregrounding the app.
- Wait longer than the old 5 minute unload interval; short dictation remains warm with `ensureLoaded: 0ms`.
- Force cold state via app restart or debug unload; one short recording produces exactly one load and an intentional preparing-model state.
- Back-to-back recordings do not duplicate load or lose transcripts.
- Concurrent call-recording/dictation behavior is deterministic.
- Unified logs can explain each request from capture start through paste in one query.

## Upstream Comparison

See [upstream-comparison.md](upstream-comparison.md).
