// DataMigrationManager.swift
// Handles data migration between different app versions

import Foundation

/// Manages data migration between different app versions
class DataMigrationManager {
    static let shared = DataMigrationManager()
    
    private init() {}
    
    /// Migrates a meeting from an older version to the current version
    /// - Parameter meeting: The meeting to migrate
    /// - Returns: The migrated meeting, or nil if migration failed
    func migrateMeeting(_ meeting: Meeting) -> Meeting? {
        // No releases prior to version 1 – any older file is considered unsupported.
        guard meeting.dataVersion >= 1 else {
            print("🚫 Cannot migrate meeting \(meeting.id) – unsupported data version \(meeting.dataVersion)")
            return nil
        }

        // Migrate 4 -> 5: add audioStorageId (nil), bump dataVersion
        if meeting.dataVersion == 4 {
            let migrated = Meeting(
                id: meeting.id,
                date: meeting.date,
                title: meeting.title,
                transcriptChunks: meeting.transcriptChunks,
                userNotes: meeting.userNotes,
                generatedNotes: meeting.generatedNotes,
                templateId: meeting.templateId,
                source: meeting.source,
                analytics: meeting.analytics,
                audioFileURL: meeting.audioFileURL,
                audioStorageId: nil,
                calendarEventId: meeting.calendarEventId,
                dataVersion: 5
            )
            return migrated
        }

        if meeting.dataVersion < Meeting.currentDataVersion {
            print("⚠️ No migration path for versions \(meeting.dataVersion + 1)...\(Meeting.currentDataVersion)")
            return nil
        }

        return meeting
    }
    
    // Future migrateXToVersionY helpers will go here as needed
    
    /// Performs a backup of the meetings directory before migration
    /// - Returns: The backup directory URL, or nil if backup failed
    func backupMeetingsDirectory() -> URL? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let meetingsDirectory = documentsDirectory.appendingPathComponent("Meetings")
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        
        let backupDirectory = documentsDirectory.appendingPathComponent("Meetings_Backup_\(timestamp)")
        
        do {
            try FileManager.default.copyItem(at: meetingsDirectory, to: backupDirectory)
            print("✅ Created backup at: \(backupDirectory)")
            return backupDirectory
        } catch {
            print("❌ Failed to create backup: \(error)")
            return nil
        }
    }
} 