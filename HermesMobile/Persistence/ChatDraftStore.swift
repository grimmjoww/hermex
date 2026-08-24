import Foundation
import os

struct ChatDraftKey: Hashable, Sendable {
    enum Context: Hashable, Sendable {
        case session(String)
        case newChat
    }

    let serverID: String
    let context: Context

    static func session(server: URL, sessionID: String) -> Self {
        Self(serverID: server.absoluteString, context: .session(sessionID))
    }

    static func newChat(server: URL) -> Self {
        Self(serverID: server.absoluteString, context: .newChat)
    }
}

protocol ChatDraftPersisting: Sendable {
    func load() async -> [ChatDraftKey: String]
    func write(_ drafts: [ChatDraftKey: String]) async throws
}

actor ChatDraftFilePersistence: ChatDraftPersisting {
    #if os(iOS)
    static let fileProtectionType = FileProtectionType.completeUntilFirstUserAuthentication
    #endif

    private struct Document: Codable {
        let version: Int?
        let drafts: [FailableRecord]?

        init(version: Int, records: [Record]) {
            self.version = version
            drafts = records.map { FailableRecord(value: $0) }
        }
    }

    private struct FailableRecord: Codable {
        let value: Record?

        init(value: Record?) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try? Record(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            guard let value else {
                var container = encoder.singleValueContainer()
                try container.encodeNil()
                return
            }
            try value.encode(to: encoder)
        }
    }

    private struct Record: Codable {
        let serverID: String?
        let context: String?
        let sessionID: String?
        let text: String?

        init(key: ChatDraftKey, text: String) {
            serverID = key.serverID
            switch key.context {
            case .session(let sessionID):
                context = "session"
                self.sessionID = sessionID
            case .newChat:
                context = "newChat"
                sessionID = nil
            }
            self.text = text
        }

        var draft: (key: ChatDraftKey, text: String)? {
            guard
                let serverID = serverID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !serverID.isEmpty,
                let context,
                let text,
                !text.isEmpty
            else {
                return nil
            }

            let key: ChatDraftKey
            switch context {
            case "session":
                guard
                    let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !sessionID.isEmpty
                else {
                    return nil
                }
                key = ChatDraftKey(serverID: serverID, context: .session(sessionID))
            case "newChat":
                key = ChatDraftKey(serverID: serverID, context: .newChat)
            default:
                return nil
            }

            return (key, text)
        }
    }

    private static let currentVersion = 1
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "ChatDraftStore"
    )

    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let baseURL = directoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = baseURL
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("drafts.json", isDirectory: false)
    }

    func load() async -> [ChatDraftKey: String] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == Self.currentVersion else { return [:] }

            return (document.drafts ?? []).reduce(into: [:]) { result, record in
                guard let draft = record.value?.draft else { return }
                result[draft.key] = draft.text
            }
        } catch {
            Self.logger.warning("Ignoring unreadable persisted chat drafts: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    func write(_ drafts: [ChatDraftKey: String]) async throws {
        let nonEmptyDrafts = drafts.filter { !$0.value.isEmpty }
        let records = nonEmptyDrafts
            .map { Record(key: $0.key, text: $0.value) }
            .sorted {
                let lhs = ($0.serverID ?? "", $0.context ?? "", $0.sessionID ?? "")
                let rhs = ($1.serverID ?? "", $1.context ?? "", $1.sessionID ?? "")
                return lhs < rhs
            }
        let data = try JSONEncoder().encode(
            Document(version: Self.currentVersion, records: records)
        )
        let directoryURL = fileURL.deletingLastPathComponent()

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try setProtectedFileAttributes(at: directoryURL)
        try data.write(to: fileURL, options: [.atomic])
        try setProtectedFileAttributes(at: fileURL)
    }

    private func setProtectedFileAttributes(at url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: Self.fileProtectionType],
            ofItemAtPath: url.path
        )
        #endif
    }
}

@MainActor
final class ChatDraftStore {
    static let shared = ChatDraftStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "ChatDraftStore"
    )

    private let persistence: any ChatDraftPersisting
    private let debounceDuration: Duration
    private var drafts: [ChatDraftKey: String] = [:]
    private var keysChangedBeforeLoad: Set<ChatDraftKey> = []
    private var loadTask: Task<[ChatDraftKey: String], Never>?
    private var persistTask: Task<Void, Never>?
    private var isLoaded = false

    init(
        persistence: any ChatDraftPersisting = ChatDraftFilePersistence(),
        debounceDuration: Duration = .milliseconds(200)
    ) {
        self.persistence = persistence
        self.debounceDuration = debounceDuration
    }

    func draft(for key: ChatDraftKey) async -> String? {
        await loadIfNeeded()
        return drafts[key]
    }

    func setDraft(_ text: String, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        if text.isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = text
        }
        schedulePersist()
    }

    func clearDraft(for key: ChatDraftKey) {
        setDraft("", for: key)
    }

    func resolveSubmission(
        submittedText: String,
        currentText: String,
        didStart: Bool,
        for key: ChatDraftKey
    ) -> String {
        if didStart {
            if currentText.isEmpty {
                clearDraft(for: key)
            }
            return currentText
        }

        if currentText.isEmpty {
            setDraft(submittedText, for: key)
            return submittedText
        }
        return currentText
    }

    func resolveConsumedInput(
        submittedText: String,
        currentText: String,
        for key: ChatDraftKey
    ) -> String {
        guard currentText == submittedText else { return currentText }
        clearDraft(for: key)
        return ""
    }

    @discardableResult
    func moveDraft(from sourceKey: ChatDraftKey, to targetKey: ChatDraftKey) -> String {
        markChangedBeforeLoad(sourceKey)
        markChangedBeforeLoad(targetKey)

        let movedText = drafts[sourceKey] ?? drafts[targetKey] ?? ""
        drafts.removeValue(forKey: sourceKey)
        if movedText.isEmpty {
            drafts.removeValue(forKey: targetKey)
        } else {
            drafts[targetKey] = movedText
        }
        schedulePersist()
        return movedText
    }

    func flush() async throws {
        persistTask?.cancel()
        persistTask = nil
        try await persistNow()
    }

    private func persistNow() async throws {
        await loadIfNeeded()
        try await persistence.write(drafts)
    }

    private func markChangedBeforeLoad(_ key: ChatDraftKey) {
        if !isLoaded {
            keysChangedBeforeLoad.insert(key)
        }
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }

        if loadTask == nil {
            let persistence = persistence
            loadTask = Task {
                await persistence.load()
            }
        }

        guard let loadTask else { return }
        let persistedDrafts = await loadTask.value
        guard !isLoaded else { return }

        for (key, text) in persistedDrafts where !keysChangedBeforeLoad.contains(key) {
            drafts[key] = text
        }
        isLoaded = true
        self.loadTask = nil
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceDuration)
                try Task.checkCancellation()
                try await persistNow()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.warning("Could not persist chat drafts: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
