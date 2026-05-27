# Parakeet Latency Spec

Raw request:

> check the runtime logs on this and figure out why this is taking so long to transcribe sometimes
> lets explore this more and build out the plan to fix. how can we make this amazing

Runtime evidence gathered on 2026-05-27 from `/usr/bin/log show --last 4h` for `com.jdleaverton.Hex`:

- Fast warm path: `Parakeet pipeline - ensureLoaded: 0ms, audioPrepare: 10ms, inference: 77ms, total: 87ms`.
- Slow cold path: `Parakeet pipeline - ensureLoaded: 30212ms, audioPrepare: 4ms, inference: 72ms, total: 30290ms`.
- Slow cold path: `Parakeet pipeline - ensureLoaded: 28409ms, audioPrepare: 6ms, inference: 64ms, total: 28480ms`.
- Worst sampled cold path: `Parakeet pipeline - ensureLoaded: 33509ms, audioPrepare: 16ms, inference: 112ms, total: 33638ms`.
- Slow paths follow `Idle timeout reached - unloading model to reclaim memory`.
- Short recordings stop before the in-recording prewarm finishes, so the stop/transcribe path waits for the remaining cold load.
- Duplicate `Starting Parakeet load variant=parakeet-tdt-0.6b-v2-coreml` lines appear for the same recording, showing in-flight load work is not deduped across prewarm and transcribe calls.

Goal:

Make Hex feel instant and trustworthy for normal dictation, while preserving memory responsibly and making cold starts explicit, measurable, and rare.
