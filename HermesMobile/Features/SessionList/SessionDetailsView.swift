import SwiftUI

/// Per-session read details (tracker item 2, reads only). The sheet's first
/// section is token usage from `GET /api/session/usage`; later reads land here
/// as additional sections (lineage report, handoff summary, worktree status,
/// recovery audit) rather than as separate screens.
@MainActor
@Observable
final class SessionDetailsViewModel {
    private(set) var usage: SessionUsageResponse?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Fatal for the sheet (request failure other than "endpoint missing").
    private(set) var errorMessage: String?
    /// True when the server predates `/api/session/usage` (404) or the session
    /// has no server ID to fetch with — the section renders a quiet
    /// unavailable note instead of an error.
    private(set) var usageIsUnavailable = false

    private let client: APIClient
    private let sessionID: String?
    /// Generation token so a slow older response never overwrites a newer
    /// load's result (same guard the cron history sheet ships).
    private var loadGeneration = 0

    init(server: URL, client: APIClient? = nil, session: SessionSummary) {
        self.client = client ?? APIClient(baseURL: server)
        self.sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.sessionID == nil || self.sessionID?.isEmpty == true {
            usageIsUnavailable = true
        }
    }

    func load() async {
        guard let sessionID, !sessionID.isEmpty else {
            usageIsUnavailable = true
            hasLoaded = true
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        // Only the generation that is still current may clear the flag — a
        // superseded response landing late must not switch the spinner off
        // while the newer load is still in flight.
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        do {
            let usage = try await client.sessionUsage(id: sessionID)
            guard generation == loadGeneration else { return }
            self.usage = usage
            errorMessage = nil
            usageIsUnavailable = false
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch APIError.http(let statusCode, _) where statusCode == 404 {
            guard generation == loadGeneration else { return }
            usageIsUnavailable = true
            errorMessage = nil
            hasLoaded = true
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = Self.errorMessage(for: error)
            hasLoaded = true
        }
    }

    private static func errorMessage(for error: Error) -> String {
        if case APIError.http(_, let body) = error, let body, !body.isEmpty {
            return body
        }
        return String(localized: "Could not load usage.")
    }
}

/// The Session details sheet, reachable from the chat toolbar and the session
/// row context menu (per-session reads live here per the parity tracker).
struct SessionDetailsView: View {
    @State private var viewModel: SessionDetailsViewModel
    @Environment(\.dismiss) private var dismiss

    init(session: SessionSummary, server: URL) {
        _viewModel = State(initialValue: SessionDetailsViewModel(server: server, session: session))
    }

    var body: some View {
        NavigationStack {
            List {
                usageSection
            }
            .navigationTitle(String(localized: "Session Details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await viewModel.load()
            }
            .refreshable {
                await viewModel.load()
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var usageSection: some View {
        Section(String(localized: "Token Usage")) {
            if let usage = viewModel.usage {
                LabeledContent(String(localized: "Input Tokens"), value: usage.inputTokens.formatted())
                LabeledContent(String(localized: "Output Tokens"), value: usage.outputTokens.formatted())
                LabeledContent(String(localized: "Total Tokens"), value: usage.totalTokens.formatted())
                if let cost = usage.estimatedCost {
                    LabeledContent(String(localized: "Estimated Cost"), value: usageFormattedCost(cost))
                }
                if let model = usage.model, !model.isEmpty {
                    LabeledContent(String(localized: "Model"), value: model)
                }
            } else if viewModel.usageIsUnavailable {
                Text(String(localized: "Token usage is not available for this session on this server."))
                    .foregroundStyle(.secondary)
            } else if let errorMessage = viewModel.errorMessage {
                ContentUnavailableView {
                    Label(String(localized: "Could not load usage."), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(String(localized: "Retry")) {
                        Task { await viewModel.load() }
                    }
                }
            } else {
                Text(String(localized: "Loading…"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
