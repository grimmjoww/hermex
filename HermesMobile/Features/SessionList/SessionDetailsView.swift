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

    // MARK: Tracker item 2 remainder: lineage / handoff / worktree / recovery

    private(set) var lineage: SessionLineageReport?
    private(set) var lineageError: String?
    /// True when the server predates the lineage endpoint (404).
    private(set) var lineageIsUnavailable = false

    private(set) var worktreeStatus: SessionWorktreeStatus?
    private(set) var worktreeError: String?
    /// False while unknown, true once the session is confirmed worktree-backed.
    private(set) var worktreeIsAvailable = false

    private(set) var recoveryAudit: SessionRecoveryAudit?
    private(set) var recoveryAuditError: String?
    /// True when the server predates the audit endpoint (404).
    private(set) var recoveryAuditIsUnavailable = false

    private(set) var handoffSummary: SessionHandoffSummary?
    private(set) var handoffSummaryError: String?
    private(set) var isGeneratingHandoffSummary = false
    /// The summary costs model tokens on the server, so it never loads with
    /// the sheet — only from an explicit user tap.
    var hasHandoffSummary: Bool { handoffSummary != nil }

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

        // The usage read stays fatal-for-its-section (as shipped); the item-2
        // reads below are all optional decor and each fails quietly.
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

        await loadLineage(generation: generation)
        await loadWorktreeStatus(generation: generation)
        await loadRecoveryAudit(generation: generation)
    }

    /// Bounded lifecycle report for the continuation chain (tip + hidden
    /// compression segments + sibling branches).
    private func loadLineage(generation: Int) async {
        guard let sessionID, !sessionID.isEmpty else { return }
        do {
            let report = try await client.sessionLineageReport(id: sessionID)
            guard generation == loadGeneration else { return }
            lineage = report
            lineageError = nil
            lineageIsUnavailable = false
        } catch is CancellationError {
            return
        } catch APIError.http(let statusCode, _) where statusCode == 404 {
            guard generation == loadGeneration else { return }
            lineageIsUnavailable = true
            lineageError = nil
        } catch {
            guard generation == loadGeneration else { return }
            lineageError = Self.errorMessage(for: error)
        }
    }

    /// Git-worktree snapshot. A non-worktree session answers 400 — that's the
    /// normal "no worktree here" case, so the section just stays hidden.
    private func loadWorktreeStatus(generation: Int) async {
        guard let sessionID, !sessionID.isEmpty else { return }
        do {
            let status = try await client.sessionWorktreeStatus(id: sessionID)
            guard generation == loadGeneration else { return }
            worktreeStatus = status
            worktreeError = nil
            worktreeIsAvailable = true
        } catch is CancellationError {
            return
        } catch APIError.http(let statusCode, _) where statusCode == 400 || statusCode == 404 {
            guard generation == loadGeneration else { return }
            worktreeIsAvailable = false
            worktreeError = nil
        } catch {
            guard generation == loadGeneration else { return }
            worktreeError = Self.errorMessage(for: error)
        }
    }

    /// Server-wide recovery audit, filtered to this session for display.
    private func loadRecoveryAudit(generation: Int) async {
        do {
            let audit = try await client.sessionRecoveryAudit()
            guard generation == loadGeneration else { return }
            recoveryAudit = audit
            recoveryAuditError = nil
            recoveryAuditIsUnavailable = false
        } catch is CancellationError {
            return
        } catch APIError.http(let statusCode, _) where statusCode == 404 {
            guard generation == loadGeneration else { return }
            recoveryAuditIsUnavailable = true
            recoveryAuditError = nil
        } catch {
            guard generation == loadGeneration else { return }
            recoveryAuditError = Self.errorMessage(for: error)
        }
    }

    /// Model-generated summary of recent activity. Runs only from an explicit
    /// user action because the server spends tokens producing it.
    func generateHandoffSummary() async {
        guard let sessionID, !sessionID.isEmpty else { return }
        isGeneratingHandoffSummary = true
        defer { isGeneratingHandoffSummary = false }
        do {
            let summary = try await client.sessionHandoffSummary(id: sessionID)
            handoffSummary = summary
            handoffSummaryError = nil
        } catch is CancellationError {
            return
        } catch {
            handoffSummaryError = Self.errorMessage(for: error)
        }
    }

    /// Audit rows that belong to the sheet's session.
    var recoveryAuditSessionItems: [SessionRecoveryAuditItem] {
        recoveryAudit?.items(forSession: sessionID) ?? []
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
                lineageSection
                handoffSection
                if viewModel.worktreeIsAvailable {
                    worktreeSection
                }
                recoverySection
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

    /// The continuation chain (tip first) plus any sibling branches.
    @ViewBuilder
    private var lineageSection: some View {
        Section(String(localized: "Lineage")) {
            if let lineage = viewModel.lineage {
                if lineage.segments.count > 1 || !lineage.children.isEmpty {
                    LabeledContent(String(localized: "Segments"), value: lineage.totalSegments.formatted())
                    if lineage.manualReview {
                        Label(String(localized: "Branches need review."), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lineage.segments, id: \.sessionID) { row in
                        lineageRow(row)
                    }
                    if !lineage.children.isEmpty {
                        ForEach(lineage.children, id: \.sessionID) { row in
                            lineageRow(row)
                        }
                    }
                } else {
                    Text(String(localized: "This session has no continuation history."))
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.lineageIsUnavailable {
                Text(String(localized: "Lineage is not available on this server."))
                    .foregroundStyle(.secondary)
            } else if let errorMessage = viewModel.lineageError {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func lineageRow(_ row: SessionLineageRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title?.isEmpty == false ? row.title! : String(localized: "Untitled"))
                    .font(.subheadline)
                if let role = row.role, role != "tip" {
                    Text(String(localized: "Hidden segment"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if row.active == true {
                Text(String(localized: "Active"))
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    /// On-demand model summary — never auto-fetched (server token cost).
    @ViewBuilder
    private var handoffSection: some View {
        Section(String(localized: "Handoff Summary")) {
            if let summary = viewModel.handoffSummary, let text = summary.summary, !text.isEmpty {
                Text(text)
                if summary.fallback == true {
                    Text(String(localized: "Generated from local content (server fallback)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage = viewModel.handoffSummaryError {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await viewModel.generateHandoffSummary() }
            } label: {
                if viewModel.isGeneratingHandoffSummary {
                    HStack {
                        ProgressView()
                        Text(String(localized: "Generating…"))
                    }
                } else {
                    Label(String(localized: "Generate Summary"), systemImage: "sparkles")
                }
            }
            .disabled(viewModel.isGeneratingHandoffSummary)
        }
    }

    /// Only rendered for worktree-backed sessions (confirmed by a 200).
    @ViewBuilder
    private var worktreeSection: some View {
        Section(String(localized: "Worktree")) {
            if let status = viewModel.worktreeStatus {
                LabeledContent(String(localized: "Path"), value: status.path ?? "—")
                if !status.exists {
                    Label(String(localized: "Worktree folder is missing from disk."), systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent(
                        String(localized: "Uncommitted Changes"),
                        value: status.dirty
                            ? String(localized: "Yes")
                            : String(localized: "No")
                    )
                    if status.untrackedCount > 0 {
                        LabeledContent(String(localized: "Untracked Files"), value: status.untrackedCount.formatted())
                    }
                    if status.aheadBehindAvailable {
                        LabeledContent(
                            String(localized: "Ahead / Behind"),
                            value: "\(status.ahead) / \(status.behind)"
                        )
                    }
                }
            } else if let errorMessage = viewModel.worktreeError {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Server-wide audit; rows are filtered to this session.
    @ViewBuilder
    private var recoverySection: some View {
        Section(String(localized: "Recovery Audit")) {
            if let audit = viewModel.recoveryAudit {
                let items = viewModel.recoveryAuditSessionItems
                if items.isEmpty {
                    Text(String(localized: "No recovery issues for this session."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind ?? String(localized: "Unknown"))
                                .font(.subheadline)
                            if let recommendation = item.recommendation {
                                Text(recommendation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if audit.unsafeToRepairCount > 0 {
                    Label(
                        String(localized: "Some sessions need manual review on the server."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.secondary)
                }
            } else if viewModel.recoveryAuditIsUnavailable {
                Text(String(localized: "Recovery audit is not available on this server."))
                    .foregroundStyle(.secondary)
            } else if let errorMessage = viewModel.recoveryAuditError {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
