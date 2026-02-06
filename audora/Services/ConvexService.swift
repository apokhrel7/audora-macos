// ConvexService.swift
// Handles interactions with Convex backend with Clerk authentication

import Foundation
import ConvexMobile
import Clerk
import Combine

/// Authentication state for the app
enum AuthState: Equatable {
    case loading
    case authenticated(userId: String)
    case unauthenticated
}

/// Service for interacting with Convex backend with Clerk authentication
@MainActor
class ConvexService: ObservableObject {
    static let shared = ConvexService()

    private var client: ConvexClient?

    @Published var authState: AuthState = .loading
    @Published var errorMessage: String?

    private init() {
        // Initialize Convex client with deployment URL
        if let deploymentURL = getConvexDeploymentURL() {
            client = ConvexClient(deploymentUrl: deploymentURL)
            print("✅ Convex client initialized with URL: \(deploymentURL)")
        } else {
            print("⚠️ Convex deployment URL not configured")
        }
        // Keep authState as .loading until loginFromCache() completes
    }

    /// Gets the Convex deployment URL from environment or configuration
    private func getConvexDeploymentURL() -> String? {
        print("🔍 [ConvexService] Looking for CONVEX_DEPLOYMENT_URL...")

        // Check environment variable
        let envUrl = ProcessInfo.processInfo.environment["CONVEX_DEPLOYMENT_URL"]
        print("   - Environment: \(envUrl ?? "not found")")

        if let url = envUrl, !url.isEmpty {
            return url
        }

        // Check Info.plist
        let plistUrl = Bundle.main.object(forInfoDictionaryKey: "CONVEX_DEPLOYMENT_URL") as? String
        print("   - Info.plist: \(plistUrl ?? "not found")")

        if let url = plistUrl, !url.isEmpty, url != "$(CONVEX_DEPLOYMENT_URL)" {
            return url
        }

        print("   ⚠️ CONVEX_DEPLOYMENT_URL not found!")
        return nil
    }

    // MARK: - Authentication

    /// Attempts to restore session from Clerk on app launch
    func loginFromCache() async -> Bool {
        print("🔐 [ConvexService] loginFromCache() called")

        // First, ensure Clerk has loaded its saved session
        print("   - Calling Clerk.shared.load()...")
        do {
            try await Clerk.shared.load()
            print("   - Clerk.load() completed")
        } catch {
            print("   ⚠️ Clerk.load() failed: \(error)")
        }

        // Check for session
        print("   - Checking for session...")
        if let session = Clerk.shared.session {
            print("   ✅ Session found: \(session.id)")
            if let user = Clerk.shared.user {
                print("   ✅ User found: \(user.id)")
                authState = .authenticated(userId: user.id)
                return true
            }
        }

        print("   ⚠️ No session found")
        authState = .unauthenticated
        return false
    }

    /// Called after Clerk sign-in completes
    func onSignInComplete() {
        if let user = Clerk.shared.user {
            authState = .authenticated(userId: user.id)
        }
    }

    /// Signs out the current user
    func logout() async {
        do {
            try await Clerk.shared.signOut()
            authState = .unauthenticated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Transcription

    // MARK: - Speechmatics Transcription

    /// Fetches a JWT for Speechmatics real-time transcription from the backend
    func getSpeechmaticsJWT() async throws -> String {
        guard let client = client else {
            print("❌ [Speechmatics] Convex client not initialized")
            throw ConvexError.clientNotInitialized
        }

        // Check authentication
        guard case .authenticated = authState else {
            print("❌ [Speechmatics] User not authenticated")
            throw ConvexError.authenticationRequired
        }

        print("🔑 [Speechmatics] Fetching JWT from backend...")
        do {
            let jwt: String = try await client.action("speechmatics:generateJWT", with: [:])
            print("   ✅ JWT fetched successfully")
            return jwt
        } catch {
            print("❌ [Speechmatics] Failed to fetch JWT: \(error)")
            print("   💡 Make sure your Convex backend has the 'speechmatics:generateJWT' action")
            print("   💡 Check that you're authenticated and the backend is accessible")
            
            // Provide more specific error messages
            let errorDescription = error.localizedDescription.lowercased()
            if errorDescription.contains("not found") || errorDescription.contains("404") {
                throw NSError(domain: "ConvexService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Backend action 'speechmatics:generateJWT' not found. Please ensure your Convex backend has this action implemented."
                ])
            } else if errorDescription.contains("unauthorized") || errorDescription.contains("401") {
                throw NSError(domain: "ConvexService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Authentication failed. Please sign in again."
                ])
            }
            throw error
        }
    }

    /// Checks if Convex is properly configured
    func isConfigured() -> Bool {
        return client != nil
    }
    // MARK: - Notes Generation

    /// Generates notes from a transcript using the backend
    /// NOTE: The backend doesn't currently have a "notes:generate" function.
    /// The web app uses different functions (transcribeAudio, processRealtimeTranscript) for summaries,
    /// but those don't support template-based note generation.
    /// 
    /// Options:
    /// 1. Create a new backend function: convex/notes.ts with export const generate = action({ ... })
    /// 2. Use conversations:importTextTranscript (but it doesn't support templates)
    /// 3. Generate notes client-side using OpenAI (if API key is available)
    func generateNotes(transcript: String, templateId: String?) async -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client = client else {
                        throw ConvexError.clientNotInitialized
                    }

                    // Check authentication
                    guard case .authenticated = authState else {
                        throw ConvexError.authenticationRequired
                    }

                    // Try to call backend action named "notes:generate"
                    // If it doesn't exist, we'll get a clear error
                    let args: [String: String] = [
                        "transcript": transcript,
                        "templateId": templateId ?? ""
                    ]

                    print("📝 [Notes] Calling backend action 'notes:generate'...")
                    print("   ⚠️ Note: This function doesn't exist in the current backend")
                    print("   💡 The web app uses 'transcribeAudio' and 'processRealtimeTranscript' for summaries")
                    print("   💡 But those don't support template-based note generation")
                    print("   💡 You need to create a new 'notes:generate' action in your Convex backend")
                    
                    let result: String = try await client.action("notes:generate", with: args)
                    print("   ✅ Notes generated successfully")

                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    print("❌ [Notes] Failed to generate notes: \(error)")
                    let errorDescription = error.localizedDescription.lowercased()
                    if errorDescription.contains("not found") || errorDescription.contains("404") {
                        print("   💡 The 'notes:generate' action is missing in your Convex backend")
                        print("   💡 The web app uses different functions that don't support templates")
                        print("   💡 You need to create a new backend function for template-based notes")
                        print("   💡 See: https://github.com/psycho-baller/audora for reference")
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    // MARK: - Audio Upload

    /// Uploads an audio file to Convex storage.
    /// - Parameters:
    ///   - audioFileURL: Local file URL to upload.
    ///   - meetingId: Meeting this file belongs to (unused by backend; for callers).
    ///   - previousStorageId: If set, the previous Convex storage file for this meeting is deleted after a successful upload so we keep one file per meeting instead of many.
    /// - Returns: The new Convex storage ID, or nil on failure.
    func uploadAudioFile(audioFileURL: URL, meetingId: UUID, previousStorageId: String? = nil) async throws -> String? {
        guard let client = client else { return nil }

        do {
            let uploadUrl: String = try await client.mutation("files:generateUploadUrl", with: [:])
            guard let url = URL(string: uploadUrl) else { return nil }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

            let data = try Data(contentsOf: audioFileURL)
            let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            struct UploadResponse: Decodable {
                let storageId: String
            }
            let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)
            let newStorageId = uploadResponse.storageId

            // Delete previous file so we keep one file per meeting (avoid redundant files on stop/resume)
            if let previous = previousStorageId, !previous.isEmpty {
                do {
                    try await deleteStorageId(previous)
                    print("🗑️ [Sync] Deleted previous Convex file: \(previous.prefix(12))...")
                } catch {
                    print("⚠️ [Sync] Failed to delete previous file \(previous.prefix(12))...: \(error.localizedDescription)")
                    print("   💡 Ensure your backend has 'files:deleteStorageId' deployed (npx convex deploy)")
                }
            } else {
                print("📤 [Sync] No previous storage ID to delete (first upload for this meeting)")
            }
            return newStorageId
        } catch {
            print("❌ [ConvexService] Failed to upload audio file: \(error)")
            throw error
        }
    }

    /// Deletes a file from Convex storage by ID. Used to remove the previous audio file when replacing with a new upload.
    func deleteStorageId(_ storageId: String) async throws {
        guard let client = client else { return }
        try await client.mutation("files:deleteStorageId", with: ["storageId": storageId])
    }
}

// MARK: - Supporting Types

struct TranscriptionSessionConfig {
    let wsUrl: String
    let authToken: String?
    let config: [String: Any]?
}

// MARK: - Convex Errors

enum ConvexError: LocalizedError {
    case clientNotInitialized
    case fileReadFailed
    case uploadFailed(String)
    case netError(String)
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "Backend not configured. Please set CONVEX_DEPLOYMENT_URL."
        case .fileReadFailed:
            return "Failed to read audio file."
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .netError(let message):
            return "Network error: \(message)"
        case .authenticationRequired:
            return "Please sign in to continue."
        }
    }
}
