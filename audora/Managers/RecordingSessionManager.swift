import Foundation
import SwiftUI
import Combine

/// Manages recording sessions at the app level to persist across navigation
@MainActor
class RecordingSessionManager: ObservableObject {
    static let shared = RecordingSessionManager()
    
    @Published var isRecording = false
    @Published var activeMeetingId: UUID?
    @Published var errorMessage: String?
    @Published var activeRecordingTranscriptChunksUpdated: [TranscriptChunk] = []
    
    private let audioManager = AudioManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let transcriptUpdateSubject = PassthroughSubject<[TranscriptChunk], Never>()
    
    // Store transcript chunks for the active recording session
    private var activeRecordingTranscriptChunks: [TranscriptChunk] = []
    
    // In-memory cache: last uploaded Convex storage ID per meeting (so we can delete it on next upload even if the previous upload just completed and disk hasn't been read yet)
    private var lastUploadedStorageIdByMeeting: [UUID: String] = [:]
    
    // Flag to prevent recursive restoration loops
    private var isRestoringChunks = false
    
    private init() {
        setupAudioManagerBindings()
        setupDebouncedSaving()
    }
    
    private func setupAudioManagerBindings() {
        // Bind to audio manager state
        audioManager.$isRecording
            .sink { [weak self] isRecording in
                self?.isRecording = isRecording
            }
            .store(in: &cancellables)
        
        audioManager.$errorMessage
            .sink { [weak self] errorMessage in
                self?.errorMessage = errorMessage
            }
            .store(in: &cancellables)
        
        // When transcript chunks change, merge them with existing chunks (don't replace when resuming)
        audioManager.$transcriptChunks
            .sink { [weak self] newChunks in
                guard let self = self, let meetingId = self.activeMeetingId else { return }
                
                // Skip if we're in the middle of restoring chunks (prevent recursive loops)
                if self.isRestoringChunks {
                    return
                }
                
                // If recording hasn't started yet, just update our tracking (for initial chunk seeding)
                if !self.isRecording {
                    // This happens when we seed chunks before starting recording
                    if !newChunks.isEmpty {
                        self.activeRecordingTranscriptChunks = newChunks
                        print("📝 Seeded \(newChunks.count) chunks before recording started")
                    }
                    return
                }
                
                // Now we're actually recording - merge chunks properly
                // CRITICAL: If we have existing chunks and new chunks become empty, preserve existing
                if !self.activeRecordingTranscriptChunks.isEmpty && newChunks.isEmpty {
                    print("⚠️ AudioManager chunks became empty, preserving \(self.activeRecordingTranscriptChunks.count) existing chunks")
                    print("   🔍 Debug: activeRecordingTranscriptChunks has \(self.activeRecordingTranscriptChunks.count) chunks")
                    print("   🔍 Debug: audioManager.transcriptChunks has \(self.audioManager.transcriptChunks.count) chunks")
                    
                    // Don't restore immediately - this might cause a loop
                    // Instead, wait a moment to see if chunks get repopulated naturally
                    // Only restore if they stay empty
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self, self.isRecording, self.activeMeetingId == meetingId else { return }
                        if self.audioManager.transcriptChunks.isEmpty && !self.activeRecordingTranscriptChunks.isEmpty && !self.isRestoringChunks {
                            print("   🔄 Restoring chunks after brief wait")
                            self.isRestoringChunks = true
                            self.audioManager.transcriptChunks = self.activeRecordingTranscriptChunks
                            // Reset flag after a moment
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                self.isRestoringChunks = false
                            }
                        }
                    }
                    return
                }
                
                // If we have existing chunks and new chunks are being added, merge them
                // This prevents overwriting existing transcript when resuming a recording
                if !self.activeRecordingTranscriptChunks.isEmpty && !newChunks.isEmpty {
                    // Get existing final chunks (these should be preserved)
                    let existingFinalChunks = self.activeRecordingTranscriptChunks.filter { $0.isFinal }
                    // Get new chunks that aren't duplicates of existing ones
                    let newUniqueChunks = newChunks.filter { newChunk in
                        !existingFinalChunks.contains { $0.id == newChunk.id }
                    }
                    // Merge: existing final chunks + new chunks (both final and interim)
                    let mergedChunks = existingFinalChunks + newUniqueChunks
                    
                    // Only update our state and UI; do NOT write back to audioManager here.
                    // Writing back causes a feedback loop (chunk count oscillates 8/9) and console spam.
                    if mergedChunks.count != self.activeRecordingTranscriptChunks.count ||
                       !mergedChunks.elementsEqual(self.activeRecordingTranscriptChunks, by: { $0.id == $1.id }) {
                        self.activeRecordingTranscriptChunks = mergedChunks
                        self.activeRecordingTranscriptChunksUpdated = mergedChunks
                        self.transcriptUpdateSubject.send(mergedChunks)
                    }
                } else if self.activeRecordingTranscriptChunks.isEmpty {
                    // No existing chunks, use new chunks
                    self.activeRecordingTranscriptChunks = newChunks
                    self.activeRecordingTranscriptChunksUpdated = newChunks
                    self.transcriptUpdateSubject.send(newChunks)
                }
                // If we have existing chunks but no new chunks, do nothing (preserve existing)
            }
            .store(in: &cancellables)
    }
    
    private func setupDebouncedSaving() {
        transcriptUpdateSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] chunks in
                guard let self = self, let activeMeetingId = self.activeMeetingId else { return }
                print("💾 Debounced save triggered for meeting: \(activeMeetingId.uuidString)")
                self.updateActiveMeetingTranscript(meetingId: activeMeetingId, chunks: chunks)
            }
            .store(in: &cancellables)
    }
    
    func startRecording(for meetingId: UUID) {
        print("🎙️ Starting recording for meeting: \(meetingId)")
        
        // Set activeMeetingId FIRST so the binding knows which meeting we're working with
        activeMeetingId = meetingId
        
        // Load the meeting to get existing transcript chunks BEFORE starting
        var hadExistingChunks = false
        var savedChunks: [TranscriptChunk] = []
        if let existingMeeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) {
            if let sid = existingMeeting.audioStorageId {
                lastUploadedStorageIdByMeeting[meetingId] = sid
            }
            let existingChunks = existingMeeting.transcriptChunks
            if !existingChunks.isEmpty {
                hadExistingChunks = true
                savedChunks = existingChunks
                activeRecordingTranscriptChunks = existingChunks
                print("📝 Loaded \(existingChunks.count) existing transcript chunks to preserve")
                print("   Chunk IDs: \(existingChunks.map { $0.id.uuidString.prefix(8) }.joined(separator: ", "))")
                
                // IMPORTANT: Set chunks in audioManager AFTER setting activeMeetingId
                // This ensures the binding can properly merge chunks when recording starts
                audioManager.transcriptChunks = existingChunks
                print("   ✅ Seeded audioManager with \(existingChunks.count) chunks")
            } else {
                activeRecordingTranscriptChunks = []
                audioManager.transcriptChunks = []
            }
        } else {
            // No existing meeting, start fresh
            activeRecordingTranscriptChunks = []
            audioManager.transcriptChunks = []
        }
        
        // Start audio recording
        AudioRecordingManager.shared.startRecording(for: meetingId)
        
        // Start recording - this will set isRecording = true, which will enable the binding
        audioManager.startRecording()
        
        // If we had existing chunks, add multiple checkpoints to restore them if they get cleared
        if hadExistingChunks {
            let chunksToRestore = savedChunks
            
            // Check immediately after recording starts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, self.isRecording, self.activeMeetingId == meetingId else { return }
                let currentChunks = self.audioManager.transcriptChunks
                if currentChunks.isEmpty || currentChunks.count < chunksToRestore.count {
                    print("🔄 [Checkpoint 1] Restoring \(chunksToRestore.count) existing transcript chunks")
                    print("   Current: \(currentChunks.count), Expected: \(chunksToRestore.count)")
                    self.activeRecordingTranscriptChunks = chunksToRestore
                    self.audioManager.transcriptChunks = chunksToRestore
                }
            }
            
            // Check again after WebSocket connection is established
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.isRecording, self.activeMeetingId == meetingId else { return }
                let currentChunks = self.audioManager.transcriptChunks
                if currentChunks.isEmpty || currentChunks.count < chunksToRestore.count {
                    print("🔄 [Checkpoint 2] Restoring \(chunksToRestore.count) existing transcript chunks after WebSocket")
                    print("   Current: \(currentChunks.count), Expected: \(chunksToRestore.count)")
                    self.activeRecordingTranscriptChunks = chunksToRestore
                    self.audioManager.transcriptChunks = chunksToRestore
                }
            }
            
            // Final check after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.isRecording, self.activeMeetingId == meetingId else { return }
                let currentChunks = self.audioManager.transcriptChunks
                if currentChunks.isEmpty || currentChunks.count < chunksToRestore.count {
                    print("🔄 [Checkpoint 3] Final restore of \(chunksToRestore.count) existing transcript chunks")
                    print("   Current: \(currentChunks.count), Expected: \(chunksToRestore.count)")
                    self.activeRecordingTranscriptChunks = chunksToRestore
                    self.audioManager.transcriptChunks = chunksToRestore
                } else {
                    print("✅ [Checkpoint 3] Chunks preserved correctly: \(currentChunks.count) chunks")
                }
            }
        }
    }
    
    func stopRecording() {
        print("🛑 Stopping recording for meeting: \(activeMeetingId?.uuidString ?? "unknown")")
        
        // Capture meeting ID before we clear it (we'll clear in the delayed block)
        let meetingIdToSave = activeMeetingId
        audioManager.stopRecording()
        
        // Save audio file immediately (synchronous)
        var audioFileURL: String? = nil
        if let meetingId = meetingIdToSave {
            if let savedAudioURL = AudioRecordingManager.shared.stopRecordingAndSave(for: meetingId) {
                audioFileURL = savedAudioURL.path
                print("✅ Audio file saved: \(savedAudioURL.path)")
                Task {
                    await uploadAudioFileToConvex(audioFileURL: savedAudioURL, meetingId: meetingId)
                }
            }
            
            // Defer save and state clear so we capture final transcript segments.
            // The server may send EndOfTranscript (and a last AddTranscript) after we send EndOfStream;
            // those are processed asynchronously. If we save and clear now, we'd persist without the
            // last segment(s) and resume would load that incomplete state.
            let urlToSave = audioFileURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                let chunksToSave = self.activeRecordingTranscriptChunks
                self.updateActiveMeeting(meetingId: meetingId, chunks: chunksToSave, audioFileURL: urlToSave)
                if self.activeMeetingId == meetingId {
                    self.activeMeetingId = nil
                    self.activeRecordingTranscriptChunks = []
                }
            }
        } else {
            activeMeetingId = nil
            activeRecordingTranscriptChunks = []
        }
    }
    
    /// Uploads audio file to Convex storage (non-blocking background task).
    /// Replaces the previous upload for this meeting so we keep one file per meeting instead of many.
    private func uploadAudioFileToConvex(audioFileURL: URL, meetingId: UUID) async {
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            print("⚠️ Audio file not found for upload: \(audioFileURL.path)")
            return
        }
        let authState = await MainActor.run { ConvexService.shared.authState }
        guard case .authenticated = authState else {
            print("⚠️ Not authenticated, skipping audio upload to Convex")
            return
        }
        // Use in-memory cache first so we don't miss the previous ID when the prior upload just completed (race with disk read)
        let previousStorageId = await MainActor.run {
            lastUploadedStorageIdByMeeting[meetingId]
                ?? LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId })?.audioStorageId
        }
        if let prev = previousStorageId {
            print("📤 [Sync] Uploading audio file to Convex (will replace previous: \(prev.prefix(12))...)")
        } else {
            print("📤 [Sync] Uploading audio file to Convex (first upload for this meeting)...")
        }
        do {
            let newStorageId = try await ConvexService.shared.uploadAudioFile(
                audioFileURL: audioFileURL,
                meetingId: meetingId,
                previousStorageId: previousStorageId
            )
            if let newStorageId = newStorageId {
                print("✅ [Sync] Audio file uploaded to Convex. Storage ID: \(newStorageId)")
                await MainActor.run {
                    lastUploadedStorageIdByMeeting[meetingId] = newStorageId
                    updateMeetingAudioStorageId(meetingId: meetingId, storageId: newStorageId)
                }
            } else {
                print("⚠️ [Sync] Audio file uploaded but no storage ID returned")
            }
        } catch {
            print("⚠️ [Sync] Failed to upload audio file to Convex: \(error.localizedDescription)")
        }
    }

    /// Updates and persists the meeting's Convex audio storage ID (so the next upload can delete this one).
    private func updateMeetingAudioStorageId(meetingId: UUID, storageId: String) {
        var meetings = LocalStorageManager.shared.loadMeetings()
        guard let index = meetings.firstIndex(where: { $0.id == meetingId }) else {
            print("⚠️ [Sync] updateMeetingAudioStorageId: meeting \(meetingId.uuidString.prefix(8))... not found in list")
            return
        }
        meetings[index].audioStorageId = storageId
        if LocalStorageManager.shared.saveMeeting(meetings[index]) {
            print("💾 [Sync] Saved audioStorageId for meeting \(meetingId.uuidString.prefix(8))...")
            NotificationCenter.default.post(name: .meetingSaved, object: meetings[index])
        } else {
            print("⚠️ [Sync] Failed to save audioStorageId for meeting \(meetingId.uuidString.prefix(8))...")
        }
    }
    
    func isRecordingMeeting(_ meetingId: UUID) -> Bool {
        return isRecording && activeMeetingId == meetingId
    }
    
    private func updateActiveMeetingTranscript(meetingId: UUID, chunks: [TranscriptChunk]) {
        updateActiveMeeting(meetingId: meetingId, chunks: chunks, audioFileURL: nil)
    }
    
    private func updateActiveMeeting(meetingId: UUID, chunks: [TranscriptChunk], audioFileURL: String?, audioStorageId: String? = nil) {
        var meetings = LocalStorageManager.shared.loadMeetings()
        if let index = meetings.firstIndex(where: { $0.id == meetingId }) {
            meetings[index].transcriptChunks = chunks
            if let audioFileURL = audioFileURL {
                meetings[index].audioFileURL = audioFileURL
            }
            if let audioStorageId = audioStorageId {
                meetings[index].audioStorageId = audioStorageId
            }
            let success = LocalStorageManager.shared.saveMeeting(meetings[index])
            if success {
                print("✅ Saved meeting: \(meetingId.uuidString)")
                NotificationCenter.default.post(name: .meetingSaved, object: meetings[index])
            } else {
                print("❌ Failed to save meeting: \(meetingId.uuidString)")
            }
        }
    }
    
    func getActiveRecordingTranscriptChunks() -> [TranscriptChunk] {
        return activeRecordingTranscriptChunks
    }
    
    /// Get transcript chunks for a specific meeting, ensuring proper data separation
    func getTranscriptChunks(for meetingId: UUID) -> [TranscriptChunk] {
        if isRecording && activeMeetingId == meetingId {
            // Return live transcript chunks for the active recording
            return activeRecordingTranscriptChunks
        } else {
            // Load saved transcript chunks from storage for non-active meetings
            if let savedMeeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingId }) {
                return savedMeeting.transcriptChunks
            }
            return []
        }
    }
} 