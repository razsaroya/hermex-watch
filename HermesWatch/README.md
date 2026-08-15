# HermesWatch — watchOS target

Implements `WATCHOS_ARCHITECTURE_SPEC.md` for the Hermex codebase. This directory
holds **source only**; the target itself is not yet declared in
`HermesMobile.xcodeproj` (see [Xcode integration](#xcode-integration)).

> **Not compiled.** This slice was authored on a Linux host with no Swift or
> Xcode toolchain, so nothing here has been built, run, or tested. Treat every
> file as reviewed-but-unverified until someone runs a watchOS build on a Mac.

---

## 1. Code sharing — why there is no `HermesShared` framework

Spec §2.1 and §5 Phase 1 ask for a `HermesShared/` framework target holding
`Models/`, `Networking/` and `Persistence/`. **This implementation shares the
same code by multi-target file membership instead**, and keeps the files where
they are.

The reason is access control. Every declaration in `HermesMobile/Models/` and
`HermesMobile/Networking/` is `internal` — `actor APIClient`, `struct
SessionSummary`, `enum SSEEvent`, all ~200 of them. A framework has its own
module boundary, so extracting them would mean marking every type, every stored
property, every initializer and every method `public`, then re-auditing which of
those are genuinely API versus accidentally exposed. That is a several-thousand-line
diff across the whole iOS app, for a refactor whose only user is the watch.

Multi-target membership gets the same result for free: each target compiles its
own copy of the source, so `internal` still means "visible within this target"
and no iOS source changes at all. Spec Phase 1's actual wording — *"group … into
a shared compilation unit accessible by both"* — is satisfied.

If a real framework is wanted later, it should be its own issue, done on a Mac
where the compiler can check the `public` surface.

### Shared file manifest

Add these **existing** files to the `HermesWatch` target's *Compile Sources*
build phase (they stay in the `HermesMobile` target too):

| Path | Files | Notes |
| --- | --- | --- |
| `HermesMobile/Models/*.swift` | all 24 | Must travel as a unit — the tolerant `KeyedDecodingContainer.decodeLossy*IfPresent` helpers that most models rely on are defined in `ChatMessage.swift`. |
| `HermesMobile/Networking/*.swift` | all 22 | `APIClient` + every `APIClient+*` extension, `SSEClient`, `Endpoints`, `APIError`, `CustomHeader`, `MultipartFormData`. |
| `HermesMobile/Auth/KeychainStore.swift` | 1 | Backing store for `WatchCredentialStore`. |

**Verified watchOS-safe:** the only imports across all 47 files are `Foundation`,
`ImageIO`, `Observation`, `os`, `OSLog`, `KeychainAccess` and
`LDSwiftEventSource`. No `UIKit`, no `SwiftUI`, no `AVFoundation`. The two SPM
packages both support watchOS, so their products must also be linked against the
watch target.

**Deliberately excluded:**

- `HermesMobile/Auth/AuthManager.swift` — 596 lines of multi-server registry,
  profile switching and cache reconciliation the watch does not need.
  `HermesWatch/Support/WatchServerContext.swift` replaces it with the three
  things a request actually needs: base URL, headers, auth flag.
- `HermesMobile/Persistence/` — SQLite offline cache. The watch reads live or
  reads the `WCSession` snapshot; it does not carry a second cache.
- `HermesMobile/Features/`, `HermesMobile/Config/` — SwiftUI/iOS-only.

**Known cost:** this compiles ~12k lines into the watch target, including
subsystems the watch never calls (`APIClient+Kanban.swift` alone is 449 lines).
Correctness first — the whole-directory manifest guarantees symbol closure,
which matters more than compile time when nobody here can run the compiler. A
follow-up slice can prune it against real build errors.

---

## 2. Directory layout

```
HermesWatch/
├── App/                  HermesWatchApp, WatchRootView
├── Audio/                WatchAudioEngine, WatchSpeechPlayer, WatchHapticFeedback
├── Complications/        HermesWatchWidget + app-group status bridge
├── Connectivity/         WatchConnectivityManager (WCSession)
├── Features/
│   ├── Approvals/        WatchApprovalCenter, ApprovalPromptView
│   ├── QuickSessions/    QuickSessionsView(Model)
│   ├── Tasks/            WatchTasksView(Model)  — cron jobs
│   └── VoiceChat/        WatchVoiceChatView(Model), VoiceOrbView, StreamingCaptionView
├── Resources/            Info.plist, HermesWatch.entitlements
└── Support/              WatchServerContext, WatchCredentialStore, WatchStatusPublisher
```

---

## 3. Known deviations from the spec

These are corrections, not shortcuts. Each one is a case where the spec assumes
a capability the server or the platform does not have.

### 3.1 There is no streaming STT or streaming TTS (spec §3.1)

The spec describes a 16 kHz PCM tap streamed to STT and "immediate playback of
streaming TTS audio chunks". The Hermes server exposes neither. Verified against
`HermesMobile/Networking/`:

- `POST /api/transcribe` takes a **complete audio clip** as multipart `file` and
  returns `{ok, transcript, error}`. One request, one transcript.
- `POST /api/tts` takes `{text, voice}` and returns a **fully buffered**
  `audio/mpeg` body (`Content-Length` set, not chunked).

Inventing a streaming socket would violate AGENTS.md rule 1. The implemented
turn is therefore:

```
record (≤30 s, capped) → WAV 16 kHz mono
    → POST /api/transcribe          → transcript
    → POST /api/chat/start          → streamId
    → SSE GET /api/chat/stream      → tokens arrive
        → split into complete sentences as they arrive
        → POST /api/tts per sentence, serialized, in order
        → enqueue each MP3 for back-to-back playback
```

Sentence-level chunking is what makes it *feel* streamed: speech starts after the
first sentence, not after the whole answer. The latency floor is one sentence,
not one token.

### 3.2 `WKExtendedRuntimeSession` is not wired up (spec §5 Phase 2)

watchOS grants extended runtime sessions only for a fixed set of session types
(self-care, mindfulness, physical therapy, alarm, workout). An agent chat is none
of them, and declaring a false type is an App Review rejection. `Info.plist`
deliberately carries no `WKBackgroundModes`, with a comment saying so.

Practical consequence: **a voice turn runs while the app is frontmost.** Dropping
the wrist mid-run suspends it. Mitigation is haptics — the user feels the
approval prompt or the completion buzz and raises their wrist. If true background
voice is a requirement, it needs a product decision first, not a code change.

### 3.3 Keychain sharing does not bridge phone → watch (spec §4.1)

The spec proposes sharing credentials via `kSecAttrAccessGroup` / iCloud
Keychain. A keychain access group shares items **between processes on one
device**; the Apple Watch is a separate device with a separate keychain, so this
does not transfer the server URL or proxy headers from the iPhone.

`WCSession` is the real transport. `WatchConnectivityManager` receives the active
server from the phone and `WatchCredentialStore` persists it in the *watch's* own
Keychain so a later standalone (phone-out-of-range) launch still works. The
entitlements file keeps a keychain access group for the watch app ↔ its widget
extension only, and says so.

> ⚠️ **The iPhone half of this sync is not implemented.** Nothing in
> `HermesMobile` currently sends a `WCSession` application context. Until that is
> added, the watch app will report "Open Hermex on iPhone" forever. This is the
> single largest remaining gap — see [Not done](#5-not-done).

### 3.4 Complications cannot read app state directly (spec §4)

A WidgetKit complication runs in a separate extension process with no access to
`WatchServerContext.shared` and no network budget on a timeline refresh. The
implementation therefore publishes a small `HermesWatchStatusSnapshot` into an
App Group `UserDefaults`, which the app writes (debounced) and the widget reads.

---

## 4. Xcode integration

Not performed. `HermesMobile.xcodeproj/project.pbxproj` is a 2,200-line
generated file, this host has no Xcode to validate an edit against, and a
malformed pbxproj breaks the build for everyone (AGENTS.md rule 5). Do this on a
Mac:

1. **File → New → Target → watchOS → App.**
   - Product Name `HermesWatch`, interface SwiftUI, language Swift.
   - Uncheck "Include Notification Scene" (not used by this slice).
   - When asked, make it a companion to `HermesMobile`, not watch-only.
2. Set the target's build settings:
   - `WATCHOS_DEPLOYMENT_TARGET = 10.0`
   - `PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER).watchkitapp`
   - `INFOPLIST_FILE = HermesWatch/Resources/Info.plist`
   - `CODE_SIGN_ENTITLEMENTS = HermesWatch/Resources/HermesWatch.entitlements`
   - Base configuration → `Config/Shared.xcconfig`, so `APP_IDENTIFIER_SUFFIX`,
     `APP_GROUP_IDENTIFIER` and `DEVELOPMENT_TEAM` resolve the same way they do
     for every other target.
3. Delete the template's generated `ContentView.swift` / `*App.swift`, then add
   every `.swift` file under `HermesWatch/` **except** `Complications/`.
4. Add the [shared file manifest](#shared-file-manifest) to the target's Compile
   Sources.
5. Link `LDSwiftEventSource` and `KeychainAccess` to the watch target
   (General → Frameworks, Libraries, and Embedded Content).
6. **File → New → Target → watchOS → Widget Extension**, named
   `HermesWatchWidget`, embedded in `HermesWatch`. Add only
   `HermesWatch/Complications/*.swift` to it, plus its own entitlements carrying
   the same App Group. `HermesWatchWidgetBundle` is that extension's `@main`;
   `HermesWatchApp` is the app's. Putting both in one target will not compile.
7. Add the watch app to the `HermesMobile` scheme's build order, or give it its
   own scheme.
8. Build for a paired simulator: `xcodebuild -scheme HermesWatch -destination
   'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'`.
   Expect to fix compile errors — none of this has seen a compiler.

---

## 5. Not done

- **iPhone → watch `WCSession` sender.** Required before the watch can reach a
  server at all. Belongs in `HermesMobile` next to `AuthManager`.
- **Xcode target declaration** (§4 above).
- **Any build or test run.** No XCTest target for the watch exists yet; the
  pure-logic pieces worth covering first are
  `WatchSpeechPlayer.splitCompleteSentences` and the WAV header writer in
  `WatchAudioEngine`.
- **Push-notification approvals.** Spec §3.2 mentions a push path; this slice
  implements the SSE path (`GET /api/approval/stream`) only.
- **App icon / asset catalog** for the watch target.
