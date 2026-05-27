# 02 - Warmth Policy

## Goal

Make the selected Parakeet model stay ready through normal app use.

## Scope

- `Hex/Clients/TranscriptionClient.swift`
- `Hex/Features/App/AppFeature.swift`
- `HexCore/Sources/HexCore/Settings/HexSettings.swift` only if a setting is added

## Implementation

1. Change the default policy from "unload after 5 minutes" to "keep selected model loaded for session".
2. Add explicit unload reasons in logs: `idle`, `memoryPressure`, `modelDeleted`, `modelSwitched`, `appQuit`.
3. Start background prewarm on app task when selected model is downloaded.
4. Do not prewarm if model bootstrap is incomplete or model is missing.
5. Do not add a setting in the first cut. The measured cost is low enough that a setting would add more product complexity than value.
6. Add a future hook point for memory-pressure unload if measurement later justifies it.

## Preferred First Cut

Remove or disable the 300s idle unload for Parakeet. Keep unload on model deletion and model switch. Do not add memory-pressure unload unless the implementation is straightforward and testable.

Measured basis:

- Loaded steady-state cost was about `+19.1M` physical footprint by `vmmap`.
- Loaded RSS delta was about `+30.0 MiB` by `ps`.
- Idle CPU was `0.0%` loaded and unloaded.
- The current idle unload buys that small RAM recovery at the cost of 28-33s cold stalls.

## Verification Gate

```bash
xcodebuild -scheme Hex -configuration Debug build
```

Manual QA:

1. Launch Hex with downloaded Parakeet selected.
2. Wait 6 minutes.
3. Record a short clip.
4. Confirm no idle unload occurred and `ensureLoaded` is 0ms.

Acceptance:

- Normal repeat dictation does not cold-load after a short idle break.
- Startup prewarm does not block recording or settings.
- Logs name any deliberate unload reason.

## Execution Notes

- Status: done
- Disabled Parakeet idle unload after transcription; Parakeet now cancels the idle timer with `parakeetSessionWarm`.
- Added explicit unload reasons for idle, model switch, and model deletion.
- Startup readiness now prewarms a downloaded selected model in the background and logs skipped/started/completed/failed states.
- Verified with `xcodebuild -scheme Hex -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
