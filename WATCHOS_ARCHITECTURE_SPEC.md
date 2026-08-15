# Hermes Watch Extension for Hermex — Technical Architecture & Planning Spec

## 1. Executive Summary

This document specifies the integration of a native **watchOS target (`HermesWatch`)** into the **Hermex** codebase (`com.uzairansar.hermesmobile`).

Hermex currently provides a robust, native iOS 18+ SwiftUI architecture with:
- `APIClient` / `SSEClient` supporting streaming chat, tool execution states, and session management.
- `CacheStore` and SQLite / UserDefaults persistence.
- `ComposerVoiceNoteRecorder` and `AttachmentAudioDetection` for voice handling.
- `HermesLiveActivityWidget` and `HermesShareExtension`.

The `HermesWatch` target extends Hermex to Apple Watch (watchOS 10+ / 11+), enabling standalone cellular/Wi-Fi operation and companion Watch-iPhone synchronization.

---

## 2. Target & Xcode Project Architecture

### 2.1 Monorepo & Target Structure
```
hermex/
├── HermesMobile/               # iOS Main Application
├── HermesMobileTests/          # Unit & Contract Tests
├── HermesLiveActivityWidget/   # iOS Widget & Dynamic Island
├── HermesShareExtension/       # Share Extension
├── HermesShared/               # (NEW Shared Framework / Target for Code Sharing)
│   ├── Models/                 # ChatMessage, Session, ToolCall, ServerAccount, ServerCatalog
│   ├── Networking/             # APIClient, Endpoints, SSEClient, HTTP headers
│   └── Persistence/            # Shared Keychain & lightweight cache
└── HermesWatch/                # (NEW watchOS 10+ Standalone App Target)
    ├── App/
    │   ├── HermesWatchApp.swift
    │   └── WatchRootView.swift
    ├── Features/
    │   ├── VoiceChat/          # Live streaming voice interface (AVAudioEngine + SSE/WS)
    │   ├── QuickSessions/      # Recent sessions list & quick resume
    │   ├── Tasks/              # View/run cron jobs from the wrist
    │   └── Approvals/          # Action approvals (smart approval / tool permission prompts)
    ├── Audio/
    │   ├── WatchAudioEngine.swift
    │   └── WatchHapticFeedback.swift
    └── Complications/
        └── HermesWatchWidget.swift  # WidgetKit Complications for watch faces
```

---

## 3. Core Watch Features

### 3.1 Live Voice-First Chat Interface
* **Real-time Streaming:** Speaks directly to Hermes Agent via existing `SSEClient` / `APIClient+Chat.swift`.
* **Audio Input:** `AVAudioEngine` input node tap (16kHz PCM downsampled for STT).
* **Audio Output:** Immediate playback of streaming TTS audio chunks received from Hermes.
* **UI States:**
  1. `Listening` (interactive waveform / microphone pulse)
  2. `Thinking` (animated glowing ring + active tool execution badge, e.g., `Running terminal...`)
  3. `Speaking` (voice wave animation + streaming transcript caption)
  4. `Idle`

### 3.2 Watch Action Approvals (Remote Control)
* When Hermes Agent encounters a command requiring user approval (e.g. git push, dangerous script), the watch receives a push notification / WebSocket event.
* Single-tap **Approve** / **Deny** directly from the Apple Watch with haptic confirmation.

### 3.3 Tasks & Status Glance
* View scheduled cron jobs and agent statuses.
* Trigger manual task execution from the wrist.

---

## 4. Connectivity & Sync Model

1. **Standalone Mode (Direct to Hermes Server):**
   * The watch connects directly to the user's Hermes server via HTTPS/WSS over Wi-Fi / LTE when away from iPhone.
   * Keychain credentials shared via Apple `kSecAttrAccessGroup` / iCloud Keychain.
2. **WatchConnectivity (Phone Pairing Sync):**
   * `WCSession` syncs active server accounts, recent sessions cache, and token settings automatically between iPhone and Apple Watch.

---

## 5. Phased Implementation Plan

### Phase 1: Shared Core Extraction (`HermesShared`)
* Group `Models/`, `Networking/` (`APIClient`, `SSEClient`, `Endpoints`), and `KeychainHelper` into a shared compilation unit accessible by both `HermesMobile` and `HermesWatch`.

### Phase 2: watchOS Target Creation
* Add `HermesWatch` target (watchOS 10.0+ deployment target) in `HermesMobile.xcodeproj`.
* Configure Bundle ID `com.uzairansar.hermesmobile.watchkitapp`.
* Setup `WKExtendedRuntimeSession` entitlements for background voice sessions.

### Phase 3: Watch Voice Subsystem & UI
* Implement `WatchAudioEngine` for low-latency microphone capture and streaming playback.
* Build `WatchRootView` and `WatchVoiceChatView` in SwiftUI optimized for 40mm-49mm displays.
* Integrate Haptic cues (`WKInterfaceDevice.current().play(.click / .success)`).

### Phase 4: Complications & Watch Actions
* Implement `WidgetKit` complication descriptors (`accessoryCircular`, `accessoryCorner`, `accessoryRectangular`).
* Add quick interactive approval actions.
