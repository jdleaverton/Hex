# 07 - Validation And Release Hygiene

## Goal

Prove the hybrid architecture and package the user-facing change correctly.

## Verification Steps

1. Confirm dirty-tree boundary before work:

```bash
git status --short
```

2. Run unit tests:

```bash
cd HexCore && swift test
```

3. Build Debug:

```bash
xcodebuild -scheme Hex -configuration Debug build
```

4. Manual runtime matrix:
   - warm short dictation
   - cold short dictation after app restart
   - dictation after more than 5 minutes idle
   - two quick clips back-to-back
   - input route change if practical
   - call-recording overlap if call recording remains in the worktree

5. Query lifecycle logs:

```bash
/usr/bin/log show --last 30m --style compact --predicate '(subsystem == "com.jdleaverton.Hex" OR subsystem == "com.kitlangton.Hex") AND (eventMessage CONTAINS "Transcription request" OR eventMessage CONTAINS "Parakeet" OR eventMessage CONTAINS "Capture engine" OR eventMessage CONTAINS "unload")'
```

6. Release build:

```bash
xcodebuild -scheme Hex -configuration Release build
```

7. Add changeset:

```bash
bun run changeset:add-ai patch "Improve dictation readiness so short recordings stay fast after idle"
```

## Acceptance

- Warm short clips are routinely under 500ms stop-to-paste.
- More than 5 minutes idle does not trigger a cold-load surprise.
- Forced cold loads are visible and single-flight.
- Concurrent Parakeet work is deterministic.
- First-word capture is not regressed.
- Logs show enough context to diagnose future regressions in one query.

## Execution Notes

- Status: done.
- Dirty-tree boundary confirmed before validation; unrelated call-recording, settings, app-icon, recording, and logging work was preserved.
- Changeset added: `.changeset/5b39b932.md`.
- `cd HexCore && swift test`: passed, 76 tests total.
- `xcodebuild -scheme Hex -configuration Debug build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`: passed.
- `xcodebuild -scheme Hex -configuration Release build -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`: passed. Xcode emitted `LLVM Profile Error: Failed to write file "default.profraw": Operation not permitted`, but the build exited 0.
- `bun run changeset:status`: blocked locally because `changeset` was not found on PATH.
- `xcodebuild test -scheme Hex -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO`: blocked by the existing scheme/test-host mismatch where `HexTests` resolves `TEST_HOST` to `Hex.app` while the scheme builds `Hex Debug.app`.
- Manual microphone/runtime matrix and unified-log latency query were not run in this non-interactive pass; runtime proof still needs a local app session with microphone permission and the Parakeet model available.
