# 03 - User-Visible Readiness

## Goal

Make cold starts legible without cluttering the recording experience.

## Scope

- `Hex/Features/Transcription/TranscriptionFeature.swift`
- `Hex/Features/Transcription/TranscriptionIndicatorView.swift`
- Optional model lifecycle status in `TranscriptionClient`

## Implementation

1. Track whether selected model is `loaded`, `loading`, or `unloaded`.
2. During recording, preserve the recording indicator but add a subtle preparing state when the model is cold-loading.
3. After stop, distinguish `preparingModel` from `transcribing`.
4. Remove or avoid tooltip text that reads like an explanation. Use compact status naming and motion/color.
5. Ensure status priority does not hide meaningful preparation state.
6. Keep warm-path UI visually identical or nearly identical to today.

## Verification Gate

```bash
xcodebuild -scheme Hex -configuration Debug build
```

Manual QA:

- Warm model: record indicator behaves as it does now, no extra noise.
- Cold model: recording remains primary, but the app visibly communicates preparation.
- Stop during cold load: status does not look like stuck inference.

Acceptance:

- User can tell when Hex is preparing the model versus actively transcribing.
- UI remains compact and menu-bar-app appropriate.
- Warm-path dictation does not show unnecessary status noise.

## Execution Notes

- Status: done
- Added `modelPreparationFinished` state flow so model prep can clear before active inference.
- Added compact `recordingPreparing` and `preparingModel` indicator states and removed the explanatory prewarm tooltip.
- Stop now explicitly awaits model readiness before inference, then returns the indicator to transcribing.
- Verified with `xcodebuild -scheme Hex -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
