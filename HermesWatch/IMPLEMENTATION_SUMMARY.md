# HermesWatch — implementation summary

Delivers `WATCHOS_ARCHITECTURE_SPEC.md` as source. 23 Swift files (~3,800 lines),
plus `Info.plist`, an entitlements file, and `README.md`.

**Read `README.md` first** — it holds the shared-code manifest, the Xcode
integration steps, and the full rationale for each spec deviation. This file is
the what-was-built-and-what-to-check record.

---

## 0. Verification status — read this before trusting anything below

**Nothing here has been compiled, built, run, or tested.** This work was done on
a Linux host with no Swift toolchain and no Xcode (`which swiftc` → nothing), so
the entire safety net normally provided by the compiler is absent. What was done
instead:

- Every API call was checked against the real source in `HermesMobile/`, not
  from memory — endpoint paths, method signatures, response field names.
- Type-name collisions between `HermesWatch` and the shared manifest: checked,
  none.
- iOS-only API usage (`UIKit`, `NavigationSplitView`, `navigationBarTitleDisplayMode`,
  `ActivityKit`): checked, none — every textual match is a comment explaining why
  the API is *not* used.
- Import set: `Foundation`, `SwiftUI`, `Observation`, `OSLog`, `os`, `WidgetKit`,
  `AVFoundation`, `WatchKit`, `WatchConnectivity`. All available on watchOS.
- Cross-file symbol references: resolved against definitions.

Expect compile errors on the first Mac build anyway. Budget for it.

---

## 1. What was built

| Area | Files | What it does |
| --- | --- | --- |
| **App shell** | `HermesWatchApp`, `WatchRootView` | `@main` scene; restores credentials, activates `WCSession`, re-syncs on `.active`. `NavigationStack` + `List` → Voice / Sessions / Tasks. Approval sheet hoisted to the root so it interrupts any screen. |
| **Server context** | `WatchServerContext`, `WatchCredentialStore`, `WatchStatusPublisher` | Watch-scoped replacement for the phone's 596-line `AuthManager`: base URL, headers, auth flag, cached `APIClient`. Keychain cache for standalone launches. Debounced writer for the complication snapshot. |
| **Connectivity** | `WatchConnectivityManager` | `WCSession` receive side, with an explicit documented wire format. `NSObject` delegate bridge hops every callback to the main actor. |
| **Audio** | `WatchAudioEngine`, `WatchSpeechPlayer`, `WatchHapticFeedback` | `AVAudioEngine` tap → `AVAudioConverter` → 16 kHz mono WAV for `/api/transcribe`. Sentence-queued MP3 playback for `/api/tts`. Six haptic cues. |
| **Voice chat** | `WatchVoiceChatViewModel`, `WatchVoiceChatView`, `VoiceOrbView`, `StreamingCaptionView` | The full turn: record → transcribe → create session → chat start → SSE → sentence-wise TTS. Four-state orb, auto-scrolling captions, tool badge. |
| **Sessions** | `QuickSessionsView(Model)` | 15 most recent sessions, newest first; resume into voice chat. |
| **Tasks** | `WatchTasksView(Model)` | Cron jobs with run-now / pause / resume. |
| **Approvals** | `WatchApprovalCenter`, `ApprovalPromptView` | `/api/approval/stream` + an immediate catch-up fetch. All four server choices, Deny separated. |
| **Complications** | `HermesWatchWidget`, `…Provider`, `…StatusSnapshot` | Four accessory families over an App Group snapshot; deep-links into the app. |

### The voice turn, end to end

```
tap Speak → AVAudioSession .playAndRecord → AVAudioEngine tap (hardware format)
  → AVAudioConverter → 16 kHz mono Int16 → RIFF/WAVE
  → POST /api/transcribe        (multipart, whole clip)
  → POST /api/session/new       (only when no session yet)
  → POST /api/chat/start        → streamId
  → SSE  /api/chat/stream       → tokens
       ├─ split into complete sentences as they arrive
       ├─ POST /api/tts per sentence, strictly serialized
       └─ enqueue each MP3 → AVAudioPlayer plays back-to-back
  → stream_end + queue drained  → idle
```

---

## 2. Defects found and fixed during review

The five drafting agents produced good code, but cross-file integration is where
parallel work breaks. Ten defects were found and fixed:

### Would have shipped broken

1. **`WatchAudioEngine` — voice input could never have worked.** The draft used
   `AVAudioConverter.convert(to:from:)`, which is documented to fail whenever the
   conversion involves a sample-rate change. Every conversion here is 44.1/48 kHz
   → 16 kHz, so every tap callback would have thrown, the `catch` would have
   swallowed it, and `stopRecording()` would have returned `.noAudioCaptured`
   every time. Rewritten onto the block-based pull API, with the long-lived
   converter kept so the resampler retains filter state across buffers.

2. **`WatchVoiceChatViewModel` — compile error.** Assigned directly to
   `WatchApprovalCenter.shared.pending` / `.sessionID`, both `private(set)`.
   Routed through `present(_:sessionID:)`, which is also what plays the arrival
   haptic and de-dupes repeat deliveries.

3. **Turn deadlock on short replies.** Completion required
   `hasEnqueuedAudioThisTurn == false`. For a one-sentence reply, playback
   finishes *before* `.streamEnd` arrives — so `onFinishedAll` fires early and
   returns, then stream-end sees audio was queued and waits for a callback that
   will never fire again. The turn hangs in `.speaking` with the mic disabled.
   Replaced with an `isSpeechPipelineIdle` check (nothing queued, nothing
   synthesizing, nothing playing).

4. **Double-POST on every approval.** `ApprovalPromptView` responded to the
   server, then `WatchRootView`'s `onResolved` responded again — for `.always`
   that writes the pattern rule twice. `onResolved` now mirrors the decision to
   the phone instead, which also gave `sendApprovalDecision` its first caller.

5. **Dismissing one approval killed all future ones.** The sheet's dismiss
   binding called `stopWatching()`, tearing down the SSE subscription. Now calls
   `dismiss()`.

6. **Complications would have rendered empty forever.**
   `HermesWatchStatusBridge.write` had zero callers. Added `WatchStatusPublisher`
   (de-duped on visible content, so it never calls `reloadAllTimelines` per
   token) and wired the voice and approval paths into it.

### Correctness / polish

7. **Approvals resolved on the phone never cleared on the watch.** Added
   handling for an explicit `pending_count: 0` — explicit only, because
   `ApprovalPendingResponse.streamPayload` also yields a nil pending for a
   payload it couldn't parse, and a malformed frame must not dismiss a live
   approval.
8. **Sentence splitter never split on newlines.** `\n` was required to be
   *followed* by whitespace. Agent replies are full of newline-delimited lists
   that would have stayed silent until the whole run finished.
9. **Both audio-session teardowns dropped `.notifyOthersOnDeactivation`**, so a
   ducked workout playlist would stay quiet after a voice turn.
10. **Force-unwrapped `URL` in the widget** built from an Info.plist string — a
    typo there would crash the extension. Also: keychain service was hardcoded
    past the branch-build suffix; `@State`-wrapped `@MainActor` singletons in
    `WatchRootView` would trip `SWIFT_STRICT_CONCURRENCY = targeted`.

---

## 3. Deviations from the spec

Full reasoning in `README.md §3`. In short:

| Spec | Reality | What was built |
| --- | --- | --- |
| §3.1 streaming STT + chunked TTS playback | Server has neither. `/api/transcribe` takes a whole clip; `/api/tts` returns a fully buffered MP3 | Record → single upload. Sentence-wise TTS so speech starts after sentence one, not after the whole reply |
| §5 Phase 2 `WKExtendedRuntimeSession` | watchOS grants these only for self-care / mindfulness / physical-therapy / alarm / workout. An agent chat is none of them; a false type is an App Review rejection | Not wired. `Info.plist` carries no `WKBackgroundModes` and says why. Voice turns run frontmost; haptics cover the gap |
| §4.1 Keychain shared via `kSecAttrAccessGroup` / iCloud Keychain | An access group shares between processes on *one device*. The watch is a separate device with a separate keychain | `WCSession` is the transport; the watch keychain is a local cache of synced values |
| §2.1 / §5 Phase 1 `HermesShared` framework | Would require marking ~200 `internal` declarations `public` across the whole iOS app — unverifiable without a compiler | Multi-target file membership. Same sharing, zero iOS source changes |
| §4 complications | Widget extension is out-of-process; can't see app state or make network calls | App Group `UserDefaults` snapshot, written debounced by `WatchStatusPublisher` |

---

## 4. What is NOT done

1. **The iPhone half of the `WCSession` sync.** Nothing in `HermesMobile` calls
   `updateApplicationContext`. **Until this exists the watch app shows "Open
   Hermex on iPhone" forever and cannot reach a server.** This is the single
   biggest gap and the natural next issue. The wire format is documented at the
   top of `WatchConnectivityManager.swift`.
2. **The Xcode target.** `HermesMobile.xcodeproj` is untouched — editing a
   2,200-line generated pbxproj with no Xcode to validate against risks breaking
   the build for everyone (AGENTS.md rule 5). `README.md §4` has the steps.
3. **Any build or test run.** No watch test target exists. The two pieces worth
   covering first are pure logic and easy to test:
   `WatchSpeechPlayer.splitCompleteSentences` and `WatchAudioEngine`'s WAV header
   writer.
4. **Push-notification approvals** (spec §3.2 mentions a push path). Only the SSE
   path is implemented.
5. **Watch app icon / asset catalog.**

## 5. Known risks for the first Mac build

- **`AVAudioApplication` availability.** `requestPermission()` guards it with
  `#available(watchOS 11.0, *)` and falls back to the deprecated
  `AVAudioSession.requestRecordPermission`. The API is believed to be watchOS
  10+, which would make the guard needlessly conservative — but this way it
  compiles under either answer, at the cost of a deprecation warning. Tighten it
  once a compiler can confirm.
- **`@Observable` on an `NSObject` subclass** (`WatchSpeechPlayer`, needed for
  `AVAudioPlayerDelegate`). Believed fine; if the macro complains, split the
  delegate into a separate `NSObject` proxy the way `WatchConnectivityManager`
  already does.
- **`WCSession` closure captures.** `sendMessage`'s reply/error handlers capture
  a `@MainActor` type and receive a non-`Sendable` `[String: Any]`. Under
  `SWIFT_STRICT_CONCURRENCY = targeted` (this project's setting) these are
  warnings, not errors. They would become errors under Swift 6 language mode.
- **Shared-manifest compile cost.** ~12k lines of `Models/` + `Networking/` are
  compiled into the watch target for symbol closure, including subsystems the
  watch never calls (`APIClient+Kanban.swift` alone is 449 lines). Prune against
  real build errors in a follow-up.
