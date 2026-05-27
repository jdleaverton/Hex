# Upstream Comparison

Evidence date: 2026-05-27

## Refs

- Original upstream: `origin` -> `https://github.com/kitlangton/Hex.git`
- Fork remote: `fork` -> `https://github.com/jdleaverton/Hex.git`
- Merge base: `f29125d` (`Release 0.6.10`)
- Upstream head fetched: `origin/main` -> `f988cb7` (`Release 0.7.6`)
- Fork remote head: `fork/main` -> `53e496a`
- Local head: `main` -> `3b07987`, with additional uncommitted worktree changes

## What Upstream Figured Out

### 1. They removed the 5 minute model unload

Current upstream `origin/main:Hex/Clients/TranscriptionClient.swift` has no `idleUnloadTask`, no 300s idle timer, and no Parakeet unload API. Once Parakeet is loaded, it stays loaded until model switch/delete/app exit.

Fork/local added:

- `idleUnloadTask`
- `idleUnloadDelay = .seconds(300)`
- `scheduleIdleUnload()`
- `idleUnload()`
- `ParakeetClient.unload()`

Runtime logs show this local policy is the direct cause of surprise 28-33s waits after normal idle periods.

Decision: adopt upstream's no-idle-unload policy for Parakeet unless memory measurements prove it is unacceptable.

### 2. They focused capture latency separately from model latency

Upstream added `Hex/Clients/SuperFastCaptureController.swift`, a warm `AVAudioEngine` capture path with:

- 16 kHz mono Float32 target format
- 1.0s ring buffer
- 0.45s default pre-roll
- stop grace timing based on observed callback cadence
- route/configuration-change recovery

This addresses first-word clipping and slow recorder start independently from model readiness.

Decision: do not conflate capture readiness with model readiness. The Parakeet fix should keep model policy simple, while separately considering whether to import upstream's capture work.

### 3. They simplified Parakeet transcription path

Upstream uses:

- `ParakeetClipPreparer.ensureMinimumDuration(url:)`
- `parakeet.transcribe(preparedClip.url)`

Local fork uses:

- `AudioPreparer.readAndPrependSilence(url:)`
- direct sample call `parakeet.transcribe(samples:)`
- chunk-boundary cleanup
- ANE warmup

Runtime logs show the local direct-sample path is extremely fast when loaded: 60-300ms. Upstream simplicity may be easier to maintain, but it does not by itself solve cold load time.

Decision: keep the local direct-sample path for now because measured warm latency is excellent. Revisit only if direct samples cause correctness regressions.

### 4. They do not have single-flight Parakeet loading either

Upstream `ParakeetClient.ensureLoaded` still awaits `AsrModels.downloadAndLoad` and `manager.initialize` directly inside an actor method. Swift actor reentrancy means duplicate callers can still enter while the first load is suspended.

Local runtime logs show duplicate `Starting Parakeet load` lines when prewarm and stop/transcribe overlap.

Decision: single-flight load dedupe is still needed. Upstream did not solve this because they removed explicit recording-time prewarm.

### 5. They do not have a strong model-readiness UI either

Upstream still has `isPrewarming`, but the status priority favors `.transcribing` and `.recording`, so model preparation is not a clear lifecycle concept.

Decision: keep the plan's model-state/UI chunk. It is still useful, especially for forced cold starts and first launch.

## Cost Of Keeping Parakeet Loaded

Observed local state while unloaded:

- Running app: `/Applications/Hex.app/Contents/MacOS/Hex`
- Loaded/warm sample: RSS `46416K`; `vmmap` physical footprint `135.8M`.
- After idle unload: RSS `15728K`; `vmmap` physical footprint `116.7M`.
- Loaded steady-state delta: about `+30.0 MiB` RSS or `+19.1M` physical footprint.
- Peak observed footprint: `281.6M`.
- Parakeet v2 cache on disk: 443 MB per cache root

This was measured in the same running process before and after the 5 minute idle unload fired. It is good enough for product policy: keeping Parakeet loaded costs tens of MB steady-state on this machine.

Expected cost:

- Disk: already paid once the model is downloaded, approximately 443 MB for v2 in each cache root that exists.
- RAM: one retained `AsrManager` with multiple Core ML models and decoder state. Measured steady-state cost is about 20-30 MB on this machine.
- CPU: near zero while idle if the loaded model is not actively transcribing.
- Energy: near zero idle cost beyond memory pressure effects.
- UX benefit: avoids 28-33s surprise waits after normal idle periods.

Recommended measurement:

1. Sample unloaded process:
   `ps -o pid,rss,vsz,pcpu,pmem,etime,command -p <pid>`
   `vmmap -summary <pid>`
2. Force/load Parakeet with one recording.
3. Sample loaded process before idle unload.
4. Wait past the old 5 minute timer and confirm no unload after the policy change.

## Recommended Combined Direction

1. Remove/disable Parakeet idle unload, matching upstream.
2. Add single-flight loading, which upstream lacks.
3. Keep direct-sample warm path unless correctness issues appear.
4. Replace silent busy returns with queued/explicit inference serialization.
5. Consider importing upstream `SuperFastCaptureController` as a separate capture-latency project, not as part of the Parakeet model-load fix.
6. Add concise lifecycle logs so this can be validated from one unified-log query.

## Useful Commands

```bash
git fetch --all --prune
git log --oneline --decorate --graph --left-right --cherry-pick --boundary origin/main...fork/main --max-count=80
git diff --find-renames --stat fork/main..origin/main -- Hex/Clients/TranscriptionClient.swift Hex/Clients/ParakeetClient.swift Hex/Clients/RecordingClient.swift Hex/Clients/SuperFastCaptureController.swift Hex/Features/Transcription/TranscriptionFeature.swift HexCore/Sources/HexCore/StoragePaths.swift
git show origin/main:Hex/Clients/TranscriptionClient.swift
git show origin/main:Hex/Clients/ParakeetClient.swift
git show origin/main:Hex/Clients/SuperFastCaptureController.swift
/usr/bin/log show --last 6h --style compact --predicate '(subsystem == "com.jdleaverton.Hex" OR subsystem == "com.kitlangton.Hex") AND (eventMessage CONTAINS "Idle timeout" OR eventMessage CONTAINS "Parakeet ensureLoaded" OR eventMessage CONTAINS "Parakeet pipeline" OR eventMessage CONTAINS "Starting Parakeet load")'
```
