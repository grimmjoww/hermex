import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

@MainActor
final class SessionDetailsViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeSession(serverID: String? = "abc123") throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = """
        {
          "session_id": "\(serverID ?? "")",
          "title": "Planning",
          "workspace": "/tmp/workspace"
        }
        """
        return try decoder.decode(SessionSummary.self, from: Data(payload.utf8))
    }

    func testLoadFetchesUsageAndPopulatesRows() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/usage")
            return apiTestJSONResponse("""
            {
              "input_tokens": 1200,
              "output_tokens": 340,
              "total_tokens": 1540,
              "estimated_cost": 0.0123,
              "model": "glm-5.3-flash"
            }
            """, for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.usageIsUnavailable)
        XCTAssertEqual(viewModel.usage?.inputTokens, 1200)
        XCTAssertEqual(viewModel.usage?.totalTokens, 1540)
    }

    func testLoadMarksUsageUnavailableOn404WithoutErrorBanner() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("{ \"error\": \"Session not found\" }", for: request, status: 404)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertTrue(viewModel.usageIsUnavailable, "A 404 means the server predates the endpoint; the section shows a quiet unavailable note.")
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.errorMessage, "An optional read must never raise the error banner.")
    }

    func testLoadSurfacesOtherHTTPErrors() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("{ \"error\": \"boom\" }", for: request, status: 500)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertFalse(viewModel.usageIsUnavailable)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testRetryAfterFailureReloadsUsage() async throws {
        var shouldFail = true
        let client = makeClient { request in
            if shouldFail {
                return apiTestJSONResponse("{ \"error\": \"boom\" }", for: request, status: 500)
            }
            return apiTestJSONResponse("""
            { "input_tokens": 5, "output_tokens": 7, "total_tokens": 12 }
            """, for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()
        XCTAssertNotNil(viewModel.errorMessage)

        shouldFail = false
        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.usage?.totalTokens, 12)
    }

    func testRequestsSkipWhenServerSessionIDIsMissing() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client,
            session: try makeSession(serverID: nil)
        )
        await viewModel.load()

        XCTAssertEqual(requestCount, 0, "Cached/CLI rows without a server session ID have nothing to fetch.")
        XCTAssertTrue(viewModel.usageIsUnavailable)
    }

    func testStaleResponseNeverOverwritesNewerLoad() async throws {
        let releaseFirst = DispatchSemaphore(value: 0)
        var loadCount = 0
        let client = makeClient { request in
            loadCount += 1
            if loadCount == 1 {
                releaseFirst.wait()
                return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 9, \"output_tokens\": 9, \"total_tokens\": 18 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        let firstLoad = Task { await viewModel.load() }
        // Give the first load a moment to start before the second supersedes it.
        try await Task.sleep(nanoseconds: 50_000_000)

        await viewModel.load()
        releaseFirst.signal()
        await firstLoad.value

        XCTAssertEqual(viewModel.usage?.totalTokens, 18, "A slow first response must not clobber the newer one.")
    }

    // MARK: - Lineage report

    func testLoadFetchesLineageReport() async throws {
        var lineageRequested = false
        let client = makeClient { request in
            if request.url?.path == "/api/session/lineage/report" {
                lineageRequested = true
                XCTAssertEqual(request.url?.query?.contains("session_id=abc123") ?? false, true)
                return apiTestJSONResponse("""
                {
                  "mutation": false,
                  "found": true,
                  "session_id": "abc123",
                  "lineage_key": "root-1",
                  "tip_session_id": "abc123",
                  "total_segments": 3,
                  "materialized_segments": 3,
                  "manual_review": false,
                  "segments": [
                    {"session_id": "abc123", "role": "tip", "title": "Planning", "started_at": 100, "updated_at": 200, "active": true},
                    {"session_id": "mid-1", "role": "hidden_segment", "title": "Planning (compressed)", "started_at": 50, "updated_at": 90, "active": false},
                    {"session_id": "root-1", "role": "hidden_segment", "title": "Planning (original)", "started_at": 10, "updated_at": 40, "active": false}
                  ],
                  "children": [
                    {"session_id": "kid-1", "role": "child_session", "title": "Branch", "started_at": 60, "updated_at": 70, "active": false}
                  ]
                }
                """, for: request)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertTrue(lineageRequested)
        XCTAssertNil(viewModel.lineageError)
        XCTAssertFalse(viewModel.lineageIsUnavailable)
        XCTAssertEqual(viewModel.lineage?.totalSegments, 3)
        XCTAssertEqual(viewModel.lineage?.segments.count, 3)
        XCTAssertEqual(viewModel.lineage?.segments.first?.sessionID, "abc123")
        XCTAssertEqual(viewModel.lineage?.children.count, 1)
        XCTAssertFalse(viewModel.lineage?.manualReview ?? true)
    }

    func testLineageUnavailableOn404Quietly() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/session/lineage/report" {
                return apiTestJSONResponse("{ \"error\": \"not found\" }", for: request, status: 404)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertTrue(viewModel.lineageIsUnavailable, "Older servers have no lineage endpoint; the section shows a quiet note.")
        XCTAssertNil(viewModel.lineageError, "An optional read must never raise an error banner.")
    }

    // MARK: - Handoff summary

    func testLoadDoesNotAutoFetchHandoffSummary() async throws {
        var handoffRequested = false
        let client = makeClient { request in
            if request.url?.path == "/api/session/handoff-summary" {
                handoffRequested = true
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertFalse(handoffRequested, "The summary costs model tokens — it must load on demand only.")
        XCTAssertFalse(viewModel.hasHandoffSummary)
    }

    func testGenerateHandoffSummaryParsesResponse() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/session/handoff-summary" {
                return apiTestJSONResponse("""
                { "ok": true, "summary": "Finished the billing refactor; next step is tests.", "message_count": 12, "rounds": 5, "fallback": false }
                """, for: request)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.generateHandoffSummary()

        XCTAssertTrue(viewModel.hasHandoffSummary)
        XCTAssertEqual(viewModel.handoffSummary?.summary, "Finished the billing refactor; next step is tests.")
        XCTAssertEqual(viewModel.handoffSummary?.rounds, 5)
        XCTAssertFalse(viewModel.handoffSummary?.fallback ?? true)
        XCTAssertNil(viewModel.handoffSummaryError)
    }

    func testHandoffSummaryErrorSurfacesFromServerBody() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/session/handoff-summary" {
                return apiTestJSONResponse("{ \"error\": \"Not enough conversation rounds to generate a summary.\" }", for: request, status: 400)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.generateHandoffSummary()

        XCTAssertFalse(viewModel.hasHandoffSummary)
        XCTAssertEqual(viewModel.handoffSummaryError, "Not enough conversation rounds to generate a summary.")
    }

    // MARK: - Worktree status

    func testLoadFetchesWorktreeStatusWhenSessionIsWorktreeBacked() async throws {
        var worktreeRequested = false
        let client = makeClient { request in
            if request.url?.path == "/api/session/worktree/status" {
                worktreeRequested = true
                return apiTestJSONResponse("""
                {
                  "status": {
                    "path": "/repo/.worktrees/abc",
                    "exists": true,
                    "dirty": true,
                    "untracked_count": 4,
                    "ahead_behind": {"ahead": 2, "behind": 1, "available": true, "upstream": "origin/main"},
                    "locked_by_stream": false,
                    "locked_by_terminal": false,
                    "listed": true
                  }
                }
                """, for: request)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertTrue(worktreeRequested)
        XCTAssertNil(viewModel.worktreeError)
        XCTAssertEqual(viewModel.worktreeStatus?.path, "/repo/.worktrees/abc")
        XCTAssertEqual(viewModel.worktreeStatus?.dirty, true)
        XCTAssertEqual(viewModel.worktreeStatus?.untrackedCount, 4)
        XCTAssertEqual(viewModel.worktreeStatus?.ahead, 2)
        XCTAssertEqual(viewModel.worktreeStatus?.behind, 1)
        XCTAssertEqual(viewModel.worktreeStatus?.aheadBehindAvailable, true)
    }

    func testWorktreeSectionSkippedForNonWorktreeSessions() async throws {
        var worktreeRequested = false
        let client = makeClient { request in
            if request.url?.path == "/api/session/worktree/status" {
                worktreeRequested = true
                // Server answers 400 "Session is not worktree-backed" for plain sessions.
                return apiTestJSONResponse("{ \"error\": \"Session is not worktree-backed\" }", for: request, status: 400)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client,
            session: try makeSession()
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.worktreeIsAvailable, "A 400/404 on worktree status means no worktree; the section stays hidden.")
        XCTAssertNil(viewModel.worktreeError, "A non-worktree session is normal, never an error.")
    }

    // MARK: - Recovery audit

    func testLoadFetchesRecoveryAuditAndScopesToSession() async throws {
        var auditRequested = false
        let client = makeClient { request in
            if request.url?.path == "/api/session/recovery/audit" {
                auditRequested = true
                return apiTestJSONResponse("""
                {
                  "status": "warn",
                  "summary": {"ok": 2, "repairable": 1, "unsafe_to_repair": 0},
                  "items": [
                    {"session_id": "abc123", "kind": "orphan_backup", "category": "repairable", "recommendation": "restore_from_bak", "live_messages": -1, "bak_messages": 7},
                    {"session_id": "other", "kind": "turn_journal_pending_turn", "category": "repairable", "recommendation": "audit_only_pending_turn_journal", "live_messages": 3, "bak_messages": -1}
                  ]
                }
                """, for: request)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertTrue(auditRequested)
        XCTAssertNil(viewModel.recoveryAuditError)
        XCTAssertEqual(viewModel.recoveryAudit?.status, "warn")
        XCTAssertEqual(viewModel.recoveryAudit?.repairableCount, 1)
        XCTAssertEqual(viewModel.recoveryAuditSessionItems.count, 1, "The sheet scopes the server-wide audit to this session's items.")
        XCTAssertEqual(viewModel.recoveryAuditSessionItems.first?.kind, "orphan_backup")
    }

    func testRecoveryAuditUnavailableOn404Quietly() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/session/recovery/audit" {
                return apiTestJSONResponse("{ \"error\": \"not found\" }", for: request, status: 404)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertTrue(viewModel.recoveryAuditIsUnavailable, "Older servers have no audit endpoint; the section shows a quiet note.")
        XCTAssertNil(viewModel.recoveryAuditError, "An optional read must never raise an error banner.")
    }

    func testRecoveryAuditHandlesFullyHealthyServer() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/session/recovery/audit" {
                return apiTestJSONResponse("""
                { "status": "ok", "summary": {"ok": 5, "repairable": 0, "unsafe_to_repair": 0}, "items": [] }
                """, for: request)
            }
            return apiTestJSONResponse("{ \"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2 }", for: request)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client, session: try makeSession())

        await viewModel.load()

        XCTAssertEqual(viewModel.recoveryAudit?.status, "ok")
        XCTAssertEqual(viewModel.recoveryAuditSessionItems.count, 0)
        XCTAssertEqual(viewModel.recoveryAudit?.okCount, 5)
        XCTAssertEqual(viewModel.recoveryAudit?.repairableCount, 0)
    }

    // MARK: - Tolerant decoding

    func testLineageDecodesTolerantlyWhenFieldsAreMissing() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let lineage = try decoder.decode(
            SessionLineageReport.self,
            from: Data("{ \"found\": true }".utf8)
        )
        XCTAssertEqual(lineage.totalSegments, 0)
        XCTAssertEqual(lineage.segments.count, 0)
        XCTAssertEqual(lineage.children.count, 0)
        XCTAssertFalse(lineage.manualReview)
        XCTAssertNil(lineage.segments.first?.title)
    }

    func testWorktreeStatusDecodesStringNumbers() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(
            SessionWorktreeStatus.self,
            from: Data("""
            { "path": "/wt", "exists": "1", "dirty": true, "untracked_count": "3",
              "ahead_behind": {"ahead": "2", "behind": 0, "available": true} }
            """.utf8)
        )
        XCTAssertEqual(status.exists, true)
        XCTAssertEqual(status.untrackedCount, 3)
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 0)
    }
}
