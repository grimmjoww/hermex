import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class ChatDraftStoreTests: XCTestCase {
    func testDraftsAreIsolatedByServerAndContext() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let serverA = URL(string: "https://one.example.com")!
        let serverB = URL(string: "https://two.example.com")!
        let firstChat = ChatDraftKey.session(server: serverA, sessionID: "chat-1")
        let secondChat = ChatDraftKey.session(server: serverA, sessionID: "chat-2")
        let otherServerChat = ChatDraftKey.session(server: serverB, sessionID: "chat-1")
        let newChat = ChatDraftKey.newChat(server: serverA)

        store.setDraft("First", for: firstChat)
        store.setDraft("Second", for: secondChat)
        store.setDraft("Other server", for: otherServerChat)
        store.setDraft("New chat", for: newChat)
        try await store.flush()

        let restoredStore = ChatDraftStore(
            persistence: persistence,
            debounceDuration: .seconds(10)
        )
        let restoredFirstChat = await restoredStore.draft(for: firstChat)
        let restoredSecondChat = await restoredStore.draft(for: secondChat)
        let restoredOtherServerChat = await restoredStore.draft(for: otherServerChat)
        let restoredNewChat = await restoredStore.draft(for: newChat)
        XCTAssertEqual(restoredFirstChat, "First")
        XCTAssertEqual(restoredSecondChat, "Second")
        XCTAssertEqual(restoredOtherServerChat, "Other server")
        XCTAssertEqual(restoredNewChat, "New chat")
    }

    func testTypingDuringHydrationWinsOverPersistedText() async throws {
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let persistence = BlockingChatDraftPersistence(initialDrafts: [key: "Persisted"])
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))

        let hydration = Task { await store.draft(for: key) }
        await persistence.waitUntilLoadStarts()
        store.setDraft("Typed while loading", for: key)
        await persistence.releaseLoad()

        let hydratedDraft = await hydration.value
        XCTAssertEqual(hydratedDraft, "Typed while loading")
        try await store.flush()
        let persistedDrafts = await persistence.latestDrafts()
        XCTAssertEqual(persistedDrafts[key], "Typed while loading")
    }

    func testDebouncedEditsFlushAsOneLatestWrite() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("a", for: key)
        store.setDraft("ab", for: key)
        store.setDraft("abc", for: key)
        try await store.flush()

        let writeCount = await persistence.writeCount()
        let persistedDrafts = await persistence.latestDrafts()
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(persistedDrafts[key], "abc")
    }

    func testFlushLandsAStillDebouncedWrite() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("Typed before backgrounding", for: key)
        try await store.flush()

        let writeCount = await persistence.writeCount()
        let persistedDrafts = await persistence.latestDrafts()
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(persistedDrafts[key], "Typed before backgrounding")
    }

    func testNewChatDraftMovesToCreatedSession() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let server = URL(string: "https://example.com")!
        let newChat = ChatDraftKey.newChat(server: server)
        let createdChat = ChatDraftKey.session(server: server, sessionID: "created-chat")

        store.setDraft("Carry this forward", for: newChat)
        XCTAssertEqual(
            store.moveDraft(from: newChat, to: createdChat),
            "Carry this forward"
        )
        try await store.flush()

        let restoredNewChat = await store.draft(for: newChat)
        let restoredCreatedChat = await store.draft(for: createdChat)
        XCTAssertNil(restoredNewChat)
        XCTAssertEqual(restoredCreatedChat, "Carry this forward")
    }

    func testSubmissionFailureRestoresExactSnapshotAndSuccessClearsIt() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let submitted = "  Preserve spacing\nexactly  "

        store.setDraft(submitted, for: key)
        let restored = store.resolveSubmission(
            submittedText: submitted,
            currentText: "",
            didStart: false,
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(restored, submitted)
        let restoredDraft = await store.draft(for: key)
        XCTAssertEqual(restoredDraft, submitted)

        let cleared = store.resolveSubmission(
            submittedText: submitted,
            currentText: "",
            didStart: true,
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(cleared, "")
        let clearedDraft = await store.draft(for: key)
        XCTAssertNil(clearedDraft)
    }

    func testTextEnteredDuringSendIsNeverClearedOrReplaced() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("New text", for: key)
        XCTAssertEqual(
            store.resolveSubmission(
                submittedText: "Submitted text",
                currentText: "New text",
                didStart: true,
                draftWasEdited: true,
                for: key
            ),
            "New text"
        )
        XCTAssertEqual(
            store.resolveSubmission(
                submittedText: "Submitted text",
                currentText: "New text",
                didStart: false,
                draftWasEdited: true,
                for: key
            ),
            "New text"
        )
        let currentDraft = await store.draft(for: key)
        XCTAssertEqual(currentDraft, "New text")

        store.clearDraft(for: key)
        let editedBackToEmpty = store.resolveSubmission(
            submittedText: "Submitted text",
            currentText: "",
            didStart: false,
            draftWasEdited: true,
            for: key
        )
        XCTAssertEqual(editedBackToEmpty, "")
        let emptyDraft = await store.draft(for: key)
        XCTAssertNil(emptyDraft)
    }

    func testNewComposerRevisionIsNotClearedEvenWhenTextMatchesConsumedInput() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("/status", for: key)
        let retained = store.resolveConsumedInput(
            submittedText: "/status",
            currentText: "/status",
            draftWasEdited: true,
            for: key
        )
        XCTAssertEqual(retained, "/status")
        let retainedDraft = await store.draft(for: key)
        XCTAssertEqual(retainedDraft, "/status")

        store.setDraft("/status", for: key)
        let cleared = store.resolveConsumedInput(
            submittedText: "/status",
            currentText: "/status",
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(cleared, "")
        let clearedDraft = await store.draft(for: key)
        XCTAssertNil(clearedDraft)
    }

    func testFilePersistenceUsesVersionedLossyDecoding() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let fileURL = directory
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("drafts.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = """
        {
          "version": 1,
          "drafts": [
            {
              "serverID": "https://example.com",
              "context": "session",
              "sessionID": "valid-chat",
              "text": "Keep this",
              "futureField": true
            },
            {
              "serverID": 42,
              "context": "session",
              "sessionID": "invalid-chat",
              "text": "Ignore this"
            },
            {
              "serverID": "https://example.com",
              "context": "future-context",
              "text": "Ignore this too"
            }
          ],
          "futureDocumentField": "ignored"
        }
        """
        try Data(document.utf8).write(to: fileURL, options: [.atomic])

        let drafts = await persistence.load()

        XCTAssertEqual(
            drafts[
                ChatDraftKey(
                    serverID: "https://example.com",
                    context: .session("valid-chat")
                )
            ],
            "Keep this"
        )
        XCTAssertEqual(drafts.count, 1)
    }

    func testFilePersistenceWritesAtomicallyWithFileProtection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .newChat
        )

        try await persistence.write([key: "Protected prompt"])

        let restoredDrafts = await persistence.load()
        XCTAssertEqual(restoredDrafts[key], "Protected prompt")
        #if os(iOS)
        XCTAssertEqual(
            ChatDraftFilePersistence.fileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor RecordingChatDraftPersistence: ChatDraftPersisting {
    private var drafts: [ChatDraftKey: String]
    private var writes = 0

    init(initialDrafts: [ChatDraftKey: String] = [:]) {
        drafts = initialDrafts
    }

    func load() async -> [ChatDraftKey: String] {
        drafts
    }

    func write(_ drafts: [ChatDraftKey: String]) async throws {
        self.drafts = drafts
        writes += 1
    }

    func latestDrafts() -> [ChatDraftKey: String] {
        drafts
    }

    func writeCount() -> Int {
        writes
    }
}

private actor BlockingChatDraftPersistence: ChatDraftPersisting {
    private let initialDrafts: [ChatDraftKey: String]
    private var latest: [ChatDraftKey: String]
    private var loadStarted = false
    private var loadStartContinuation: CheckedContinuation<Void, Never>?
    private var loadReleaseContinuation: CheckedContinuation<Void, Never>?

    init(initialDrafts: [ChatDraftKey: String]) {
        self.initialDrafts = initialDrafts
        latest = initialDrafts
    }

    func load() async -> [ChatDraftKey: String] {
        loadStarted = true
        loadStartContinuation?.resume()
        loadStartContinuation = nil
        await withCheckedContinuation { continuation in
            loadReleaseContinuation = continuation
        }
        return initialDrafts
    }

    func write(_ drafts: [ChatDraftKey: String]) async throws {
        latest = drafts
    }

    func waitUntilLoadStarts() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { continuation in
            loadStartContinuation = continuation
        }
    }

    func releaseLoad() {
        loadReleaseContinuation?.resume()
        loadReleaseContinuation = nil
    }

    func latestDrafts() -> [ChatDraftKey: String] {
        latest
    }
}
