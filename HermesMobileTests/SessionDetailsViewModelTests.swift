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
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

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
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.usageIsUnavailable, "A 404 means the server predates the endpoint; the section shows a quiet unavailable note.")
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.errorMessage, "An optional read must never raise the error banner.")
    }

    func testLoadSurfacesOtherHTTPErrors() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("{ \"error\": \"boom\" }", for: request, status: 500)
        }
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

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
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

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
        let viewModel = SessionDetailsViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        let firstLoad = Task { await viewModel.load() }
        // Give the first load a moment to start before the second supersedes it.
        try await Task.sleep(nanoseconds: 50_000_000)

        await viewModel.load()
        releaseFirst.signal()
        await firstLoad.value

        XCTAssertEqual(viewModel.usage?.totalTokens, 18, "A slow first response must not clobber the newer one.")
    }
}
