# macOS app vs backend (Convex / web) alignment

This doc summarizes how the **macOS app** (audora-macos) relates to the **backend** (Convex at `audora/packages/backend/convex` and web app at `audora/apps/web`). It clarifies that **no restructure of the macOS app is required** for the backend changes described in the other Cursor summary.

---

## 1. Who uses what

| Backend piece | Used by web app? | Used by macOS app? |
|---------------|-------------------|---------------------|
| `speechmatics:generateJWT` | ✅ (real-time Speechmatics) | ✅ (real-time Speechmatics) |
| `processRealtimeTranscript` | ✅ (on recording stop) | ❌ |
| `conversations.saveTranscriptData` | ✅ (from processRealtimeTranscript) | ❌ |
| `files:generateUploadUrl` | ✅ | ✅ (audio upload on stop) |
| `notes:generate` | (varies) | ✅ (Generate notes) |

- **Web flow**: Browser records → Speechmatics real-time → `AddTranscript` builds `transcriptTurns` (speaker, text, startTime, endTime, words) → on stop calls **processRealtimeTranscript(conversationId, transcriptTurns, …)** → backend runs AI (facts/summary) and **saveTranscriptData** (conversations + transcriptTurns).
- **macOS flow**: App records → Speechmatics real-time → we build **transcriptChunks** (source: mic/system, text, isFinal) → stored **locally** in the meeting (LocalStorage). On stop we only **upload the audio file** to Convex via `files:generateUploadUrl`. Notes use **notes:generate** with the meeting’s `formattedTranscript` (no conversation or transcriptTurns).

So: **macOS does not call `processRealtimeTranscript` or `saveTranscriptData`.** No duplicate-transcript migration or “processRealtimeTranscript called twice” risk applies to the macOS app.

---

## 2. Transcript shape

- **Backend expects (processRealtimeTranscript):**  
  `transcriptTurns`: `{ speaker, text, startTime, endTime, words? }[]` with S1/S2 mapping and conversationId.
- **macOS has:**  
  `transcriptChunks`: `{ source: .mic | .system, text, isFinal, timestamp }[]` stored on the **meeting** (TranscriptionSession).  
  We map source to display names “Me” / “Them” only in the UI.

No restructure is needed for current behavior: macOS keeps transcript local and does not send it to the conversation pipeline.

---

## 3. Turn-level timestamps (backend)

The backend schema has `transcriptTurns.timestamp` (and word-level start/end), but **saveTranscriptData** currently does not accept or persist turn-level `startTime`/`timestamp`. That’s a backend gap (e.g. from “add turn level timestamps” not fully wired). The macOS app does not depend on it.

---

## 4. Duplicate transcript migration (backend)

The migration that removes duplicate transcript turns applies to **web** usage (processRealtimeTranscript sometimes called twice). The macOS app never writes to `transcriptTurns`, so no code change is needed on macOS for that migration.

---

## 5. Speechmatics config (enable_partials)

- **Web (CurrentView):** `enable_partials: false`; only `AddTranscript`; commit on `is_eos`.
- **macOS (AudioManager):** We aligned with this: `enable_partials: false`, accumulate words, commit on `is_eos`, send **EndOfStream** on pause so sessions are released. No change needed.

---

## 6. Optional future: syncing macOS transcript to Convex

If we later want macOS to feed into the same conversation/facts/summary pipeline as the web:

- Backend would need an API that either:
  - accepts “meeting” transcript (e.g. array of `{ speaker: "Me"|"Them", text, startTime?, endTime? }`) and creates/updates a conversation and runs the same AI + saveTranscriptData, or
  - reuses `processRealtimeTranscript` with a conversationId and turns derived from `transcriptChunks` (map mic → S1, system → S2; use `chunk.timestamp` for startTime/endTime if the backend starts persisting them).
- macOS would then send transcript (and optionally audio reference) when recording stops, in addition to the current audio upload.

This would be a **new feature**, not a restructure of existing macOS logic.

---

## 7. Summary

- **No restructure needed** for the macOS app with respect to:
  - processRealtimeTranscript / saveTranscriptData
  - Duplicate transcript migration
  - Turn-level timestamps (backend-only gap)
  - enable_partials / is_eos (already aligned)
- **Current macOS behavior is correct:** local transcript, audio upload to Convex, notes via notes:generate. Optional later step is to add a path that sends transcript (and maybe conversation id) to the backend if we want parity with the web conversation pipeline.
