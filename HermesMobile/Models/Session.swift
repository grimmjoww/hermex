import Foundation

struct SessionsResponse: Decodable {
    let sessions: [SessionSummary]?
    let cliCount: Int?
    /// Total archived sessions in the active profile (`archived_count`), present
    /// on every response regardless of `include_archived` (issue #17). Optional so
    /// older servers that omit it decode fine.
    let archivedCount: Int?
    let serverTime: Double?
    let serverTz: String?

    enum CodingKeys: String, CodingKey {
        case sessions, cliCount, archivedCount, serverTime, serverTz
    }

    init(
        sessions: [SessionSummary]? = nil,
        cliCount: Int? = nil,
        archivedCount: Int? = nil,
        serverTime: Double? = nil,
        serverTz: String? = nil
    ) {
        self.sessions = sessions
        self.cliCount = cliCount
        self.archivedCount = archivedCount
        self.serverTime = serverTime
        self.serverTz = serverTz
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = SessionSummary.decodingRowsIndependently(from: container, forKey: .sessions)
        cliCount = container.decodeLossyIntIfPresent(forKey: .cliCount)
        archivedCount = container.decodeLossyIntIfPresent(forKey: .archivedCount)
        serverTime = container.decodeLossyDoubleIfPresent(forKey: .serverTime)
        serverTz = container.decodeLossyStringIfPresent(forKey: .serverTz)
    }
}

struct SessionSearchResponse: Decodable, Equatable {
    let sessions: [SessionSummary]?
    let query: String?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case sessions, query, count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = SessionSummary.decodingRowsIndependently(from: container, forKey: .sessions)
        query = container.decodeLossyStringIfPresent(forKey: .query)
        count = container.decodeLossyIntIfPresent(forKey: .count)
    }
}

struct SessionResponse: Decodable {
    let session: SessionDetail?
}

struct SessionMutationResponse: Decodable {
    let ok: Bool?
    let session: SessionSummary?
    let error: String?
}

/// GET /api/session/usage — token counters for one session
/// (upstream `session_ops.session_usage`). Keys stay camelCase (the shared
/// client decoder converts snake_case) and every field decodes tolerantly:
/// servers without the endpoint answer 404 (handled by callers), and older
/// payloads may omit the optional cost/model fields.
struct SessionUsageResponse: Decodable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCost: Double?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, totalTokens, estimatedCost, model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens) ?? 0
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens) ?? 0
        totalTokens = container.decodeLossyIntIfPresent(forKey: .totalTokens) ?? 0
        estimatedCost = container.decodeLossyDoubleIfPresent(forKey: .estimatedCost)
        model = container.decodeLossyStringIfPresent(forKey: .model)
    }
}

// MARK: - Session details reads (tracker #395 item 2)
//
// Shapes mirror `api/agent_sessions.py` (lineage report), `api/worktrees.py`
// (worktree status), `api/session_recovery.py` (recovery audit) and the
// handoff-summary handler in `api/routes.py` in hermes-webui. Keys stay
// camelCase (the shared client decoder converts snake_case) and every field
// decodes lossily so partial payloads never throw.

/// One row of a lineage report (`segments` / `children` arrays).
struct SessionLineageRow: Decodable, Equatable {
    let sessionID: String?
    let role: String?
    let title: String?
    let source: String?
    let startedAt: Double?
    let updatedAt: Double?
    let endReason: String?
    let active: Bool?
    let archived: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID, role, title, source, startedAt, updatedAt, endReason, active, archived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.decodeLossyStringIfPresent(forKey: .sessionID)
        role = container.decodeLossyStringIfPresent(forKey: .role)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        source = container.decodeLossyStringIfPresent(forKey: .source)
        startedAt = container.decodeLossyDoubleIfPresent(forKey: .startedAt)
        updatedAt = container.decodeLossyDoubleIfPresent(forKey: .updatedAt)
        endReason = container.decodeLossyStringIfPresent(forKey: .endReason)
        active = container.decodeLossyBoolIfPresent(forKey: .active)
        archived = container.decodeLossyBoolIfPresent(forKey: .archived)
    }
}

/// GET /api/session/lineage/report — bounded lifecycle report for a session's
/// continuation lineage. `segments` lists the continuation chain (tip first),
/// `children` lists sibling branches hanging off that chain.
struct SessionLineageReport: Decodable, Equatable {
    let found: Bool
    let lineageKey: String?
    let tipSessionID: String?
    let totalSegments: Int
    let manualReview: Bool
    let segments: [SessionLineageRow]
    let children: [SessionLineageRow]

    enum CodingKeys: String, CodingKey {
        case found, lineageKey, tipSessionID, totalSegments, materializedSegments, manualReview, segments, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = container.decodeLossyBoolIfPresent(forKey: .found) ?? false
        lineageKey = container.decodeLossyStringIfPresent(forKey: .lineageKey)
        tipSessionID = container.decodeLossyStringIfPresent(forKey: .tipSessionID)
        totalSegments = container.decodeLossyIntIfPresent(forKey: .totalSegments)
            ?? container.decodeLossyIntIfPresent(forKey: .materializedSegments)
            ?? 0
        manualReview = container.decodeLossyBoolIfPresent(forKey: .manualReview) ?? false
        segments = (try? container.decodeIfPresent([SessionLineageRow].self, forKey: .segments)) ?? []
        children = (try? container.decodeIfPresent([SessionLineageRow].self, forKey: .children)) ?? []
    }
}

/// Ahead/behind counters inside `GET /api/session/worktree/status`.
struct SessionWorktreeAheadBehind: Decodable, Equatable {
    let ahead: Int
    let behind: Int
    let available: Bool
    let upstream: String?

    enum CodingKeys: String, CodingKey {
        case ahead, behind, available, upstream
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ahead = container.decodeLossyIntIfPresent(forKey: .ahead) ?? 0
        behind = container.decodeLossyIntIfPresent(forKey: .behind) ?? 0
        available = container.decodeLossyBoolIfPresent(forKey: .available) ?? false
        upstream = container.decodeLossyStringIfPresent(forKey: .upstream)
    }
}

/// GET /api/session/worktree/status — read-only snapshot of the session's git
/// worktree. Only worktree-backed sessions have one; plain sessions get a 400
/// ("Session is not worktree-backed"), which callers treat as "no section".
struct SessionWorktreeStatus: Decodable, Equatable {
    let path: String?
    let exists: Bool
    let dirty: Bool
    let untrackedCount: Int
    let ahead: Int
    let behind: Int
    let aheadBehindAvailable: Bool
    let upstream: String?
    let lockedByStream: Bool
    let lockedByTerminal: Bool
    let listed: Bool

    enum CodingKeys: String, CodingKey {
        case path, exists, dirty, untrackedCount, aheadBehind
        case lockedByStream, lockedByTerminal, listed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = container.decodeLossyStringIfPresent(forKey: .path)
        exists = container.decodeLossyBoolIfPresent(forKey: .exists) ?? false
        dirty = container.decodeLossyBoolIfPresent(forKey: .dirty) ?? false
        untrackedCount = container.decodeLossyIntIfPresent(forKey: .untrackedCount) ?? 0
        lockedByStream = container.decodeLossyBoolIfPresent(forKey: .lockedByStream) ?? false
        lockedByTerminal = container.decodeLossyBoolIfPresent(forKey: .lockedByTerminal) ?? false
        listed = container.decodeLossyBoolIfPresent(forKey: .listed) ?? false
        if let aheadBehind = try? container.decodeIfPresent(SessionWorktreeAheadBehind.self, forKey: .aheadBehind) {
            ahead = aheadBehind.ahead
            behind = aheadBehind.behind
            aheadBehindAvailable = aheadBehind.available
            upstream = aheadBehind.upstream
        } else {
            ahead = 0
            behind = 0
            aheadBehindAvailable = false
            upstream = nil
        }
    }
}

/// One repairable/unsafe finding from the recovery audit.
struct SessionRecoveryAuditItem: Decodable, Equatable, Hashable {
    let sessionID: String?
    let kind: String?
    let category: String?
    let recommendation: String?
    let liveMessages: Int?
    let bakMessages: Int?

    enum CodingKeys: String, CodingKey {
        case sessionID, kind, category, recommendation, liveMessages, bakMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.decodeLossyStringIfPresent(forKey: .sessionID)
        kind = container.decodeLossyStringIfPresent(forKey: .kind)
        category = container.decodeLossyStringIfPresent(forKey: .category)
        recommendation = container.decodeLossyStringIfPresent(forKey: .recommendation)
        liveMessages = container.decodeLossyIntIfPresent(forKey: .liveMessages)
        bakMessages = container.decodeLossyIntIfPresent(forKey: .bakMessages)
    }
}

/// GET /api/session/recovery/audit — server-wide recovery health snapshot.
/// The endpoint takes no session parameter; the app filters `items` down to
/// the viewed session for the per-session sheet.
struct SessionRecoveryAudit: Decodable, Equatable {
    let status: String?
    let okCount: Int
    let repairableCount: Int
    let unsafeToRepairCount: Int
    let items: [SessionRecoveryAuditItem]

    enum CodingKeys: String, CodingKey {
        case status, summary, items
    }

    private enum SummaryKeys: String, CodingKey {
        case ok, repairable, unsafeToRepair
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        items = (try? container.decodeIfPresent([SessionRecoveryAuditItem].self, forKey: .items)) ?? []
        if let summary = try? container.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary) {
            okCount = summary.decodeLossyIntIfPresent(forKey: .ok) ?? 0
            repairableCount = summary.decodeLossyIntIfPresent(forKey: .repairable) ?? 0
            unsafeToRepairCount = summary.decodeLossyIntIfPresent(forKey: .unsafeToRepair) ?? 0
        } else {
            okCount = 0
            repairableCount = 0
            unsafeToRepairCount = 0
        }
    }

    /// The audit items that belong to a given session.
    func items(forSession sessionID: String?) -> [SessionRecoveryAuditItem] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        return items.filter { $0.sessionID == sessionID }
    }
}

/// POST /api/session/handoff-summary — model-generated summary of recent
/// activity. Costs tokens on the server, so the app only calls it on demand.
struct SessionHandoffSummary: Decodable, Equatable {
    let ok: Bool?
    let summary: String?
    let messageCount: Int?
    let rounds: Int?
    let fallback: Bool?
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case ok, summary, messageCount, rounds, fallback, warning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        summary = container.decodeLossyStringIfPresent(forKey: .summary)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
        rounds = container.decodeLossyIntIfPresent(forKey: .rounds)
        fallback = container.decodeLossyBoolIfPresent(forKey: .fallback)
        warning = container.decodeLossyStringIfPresent(forKey: .warning)
    }
}

struct ProjectsResponse: Decodable, Equatable {
    let projects: [ProjectSummary]?

    enum CodingKeys: String, CodingKey {
        case projects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try? container.decodeIfPresent([ProjectSummary].self, forKey: .projects)
    }
}

struct ProjectMutationResponse: Decodable, Equatable {
    let ok: Bool?
    let project: ProjectSummary?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case project
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        project = try? container.decodeIfPresent(ProjectSummary.self, forKey: .project)
        error = container.decodeLossyStringIfPresent(forKey: .error)
    }
}

struct ProjectSummary: Decodable, Equatable, Hashable, Identifiable {
    var id: String { projectId ?? name ?? UUID().uuidString }

    let projectId: String?
    let name: String?
    let color: String?
    let createdAt: Double?

    enum CodingKeys: String, CodingKey {
        case projectId
        case name
        case color
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = container.decodeLossyStringIfPresent(forKey: .projectId)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        color = container.decodeLossyStringIfPresent(forKey: .color)
        createdAt = container.decodeLossyDoubleIfPresent(forKey: .createdAt)
    }
}

struct SessionBranchResponse: Decodable, Equatable {
    let sessionId: String?
    let title: String?
    let parentSessionId: String?
    let error: String?
}

struct SessionCompressResponse: Decodable, Equatable {
    let ok: Bool?
    let session: SessionDetail?
    let summary: SessionCompressionSummary?
    let focusTopic: String?
    let error: String?
}

struct SessionCompressionSummary: Decodable, Equatable {
    let headline: String?
    let tokenLine: String?
    let note: String?
    let referenceMessage: String?

    var compressedTokenEstimate: Int? {
        guard let tokenLine, !tokenLine.isEmpty else { return nil }

        let trailingTokenText = tokenLine
            .components(separatedBy: "\u{2192}")
            .last?
            .components(separatedBy: "->")
            .last ?? tokenLine

        let digits = trailingTokenText.filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

struct SessionUndoResponse: Decodable, Equatable {
    let ok: Bool?
    let removedCount: Int?
    let removedPreview: String?
    let error: String?
}

struct SessionRetryResponse: Decodable, Equatable {
    let ok: Bool?
    let lastUserText: String?
    let removedCount: Int?
    let error: String?
}

struct SessionStatusResponse: Decodable, Equatable {
    let sessionId: String?
    let activeStreamId: String?
    let isStreaming: Bool?
    let pendingUserMessage: String?
    let error: String?
}

struct SessionSummary: Decodable, Equatable, Hashable, Identifiable {
    var id: String {
        if let sessionId, !sessionId.isEmpty {
            return sessionId
        }

        let titlePart = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "untitled"
        let timestamp = createdAt ?? updatedAt ?? lastMessageAt ?? 0
        return "session-\(titlePart)-\(timestamp)"
    }

    let sessionId: String?
    let title: String?
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let messageCount: Int?
    let createdAt: Double?
    let updatedAt: Double?
    let lastMessageAt: Double?
    let pinned: Bool?
    let archived: Bool?
    let projectId: String?
    let profile: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCost: Double?
    let activeStreamId: String?
    let isStreaming: Bool?
    let isCliSession: Bool?
    let userMessageCount: Int?
    let hasPendingUserMessage: Bool?
    let pendingStartedAt: Double?
    let worktreePath: String?
    let sourceTag: String?
    let rawSource: String?
    let sessionSource: String?
    let sourceLabel: String?
    let parentSessionId: String?
    let relationshipType: String?
    let readOnly: Bool?
    let isReadOnly: Bool?
    let matchType: String?
    /// Server-built excerpt of the matched message text on a content-search row
    /// (`match_preview`, upstream `_session_search_preview`, <=124 chars and
    /// redacted like the title). Absent on title matches, on every non-search
    /// response, and on servers older than the commit that added it.
    let matchPreview: String?

    init(
        sessionId: String? = nil,
        title: String? = nil,
        workspace: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        messageCount: Int? = nil,
        createdAt: Double? = nil,
        updatedAt: Double? = nil,
        lastMessageAt: Double? = nil,
        pinned: Bool? = nil,
        archived: Bool? = nil,
        projectId: String? = nil,
        profile: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        estimatedCost: Double? = nil,
        activeStreamId: String? = nil,
        isStreaming: Bool? = nil,
        isCliSession: Bool? = nil,
        userMessageCount: Int? = nil,
        hasPendingUserMessage: Bool? = nil,
        pendingStartedAt: Double? = nil,
        worktreePath: String? = nil,
        sourceTag: String? = nil,
        rawSource: String? = nil,
        sessionSource: String? = nil,
        sourceLabel: String? = nil,
        parentSessionId: String? = nil,
        relationshipType: String? = nil,
        readOnly: Bool? = nil,
        isReadOnly: Bool? = nil,
        matchType: String? = nil,
        matchPreview: String? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.workspace = workspace
        self.model = model
        self.modelProvider = modelProvider
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.pinned = pinned
        self.archived = archived
        self.projectId = projectId
        self.profile = profile
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCost = estimatedCost
        self.activeStreamId = activeStreamId
        self.isStreaming = isStreaming
        self.isCliSession = isCliSession
        self.userMessageCount = userMessageCount
        self.hasPendingUserMessage = hasPendingUserMessage
        self.pendingStartedAt = pendingStartedAt
        self.worktreePath = worktreePath
        self.sourceTag = sourceTag
        self.rawSource = rawSource
        self.sessionSource = sessionSource
        self.sourceLabel = sourceLabel
        self.parentSessionId = parentSessionId
        self.relationshipType = relationshipType
        self.readOnly = readOnly
        self.isReadOnly = isReadOnly
        self.matchType = matchType
        self.matchPreview = matchPreview
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, title, workspace, model, modelProvider
        case messageCount, createdAt, updatedAt, lastMessageAt
        case pinned, archived, projectId, profile
        case inputTokens, outputTokens, estimatedCost
        case activeStreamId, isStreaming, isCliSession
        case userMessageCount, hasPendingUserMessage, pendingStartedAt, worktreePath
        case sourceTag, rawSource, sessionSource, sourceLabel
        case parentSessionId, relationshipType, readOnly, isReadOnly, matchType, matchPreview
    }

    /// Lossy field by field, like `SessionDetail` and `ProjectSummary` already
    /// are (`AGENTS.md` hard rule 3).
    ///
    /// The synthesized `Decodable` this replaces failed the whole value on one
    /// mistyped field, and `SessionsResponse` decoded the array as a unit — so a
    /// single malformed row emptied the entire session list, with pull-to-refresh
    /// unable to recover it. The rows come from three different sources (sidecar
    /// JSON, the state.db overlay, `get_cli_sessions()`), and upstream coerces
    /// these same fields with `_numeric_count` / `_safe_first` on its way out,
    /// which is the server conceding the inputs are not uniform.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        workspace = container.decodeLossyStringIfPresent(forKey: .workspace)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        modelProvider = container.decodeLossyStringIfPresent(forKey: .modelProvider)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
        createdAt = container.decodeLossyDoubleIfPresent(forKey: .createdAt)
        updatedAt = container.decodeLossyDoubleIfPresent(forKey: .updatedAt)
        lastMessageAt = container.decodeLossyDoubleIfPresent(forKey: .lastMessageAt)
        pinned = container.decodeLossyBoolIfPresent(forKey: .pinned)
        archived = container.decodeLossyBoolIfPresent(forKey: .archived)
        projectId = container.decodeLossyStringIfPresent(forKey: .projectId)
        profile = container.decodeLossyStringIfPresent(forKey: .profile)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        estimatedCost = container.decodeLossyDoubleIfPresent(forKey: .estimatedCost)
        activeStreamId = container.decodeLossyStringIfPresent(forKey: .activeStreamId)
        isStreaming = container.decodeLossyBoolIfPresent(forKey: .isStreaming)
        isCliSession = container.decodeLossyBoolIfPresent(forKey: .isCliSession)
        userMessageCount = container.decodeLossyIntIfPresent(forKey: .userMessageCount)
        hasPendingUserMessage = container.decodeLossyBoolIfPresent(forKey: .hasPendingUserMessage)
        pendingStartedAt = container.decodeLossyDoubleIfPresent(forKey: .pendingStartedAt)
        worktreePath = container.decodeLossyStringIfPresent(forKey: .worktreePath)
        sourceTag = container.decodeLossyStringIfPresent(forKey: .sourceTag)
        rawSource = container.decodeLossyStringIfPresent(forKey: .rawSource)
        sessionSource = container.decodeLossyStringIfPresent(forKey: .sessionSource)
        sourceLabel = container.decodeLossyStringIfPresent(forKey: .sourceLabel)
        parentSessionId = container.decodeLossyStringIfPresent(forKey: .parentSessionId)
        relationshipType = container.decodeLossyStringIfPresent(forKey: .relationshipType)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
        isReadOnly = container.decodeLossyBoolIfPresent(forKey: .isReadOnly)
        matchType = container.decodeLossyStringIfPresent(forKey: .matchType)
        matchPreview = container.decodeLossyStringIfPresent(forKey: .matchPreview)
    }

    /// Decodes a session array a row at a time, so one unreadable row costs that
    /// row instead of the whole list. Returns nil only when the key is absent
    /// or is not an array at all.
    static func decodingRowsIndependently<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [SessionSummary]? {
        if let rows = try? container.decodeIfPresent([SessionSummary].self, forKey: key) {
            return rows
        }

        guard let values = try? container.decodeIfPresent([JSONValue].self, forKey: key) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return values.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(SessionSummary.self, from: data)
        }
    }

    init(from detail: SessionDetail) {
        sessionId = detail.sessionId
        title = detail.title
        workspace = detail.workspace
        model = detail.model
        modelProvider = detail.modelProvider
        messageCount = detail.messageCount ?? detail.messages?.count
        createdAt = detail.createdAt
        updatedAt = detail.updatedAt
        lastMessageAt = detail.lastMessageAt
        pinned = detail.pinned
        archived = detail.archived
        projectId = detail.projectId
        profile = detail.profile
        inputTokens = detail.inputTokens
        outputTokens = detail.outputTokens
        estimatedCost = detail.estimatedCost
        activeStreamId = detail.activeStreamId
        isStreaming = nil
        isCliSession = detail.isCliSession
        userMessageCount = nil
        if Self.nonEmpty(detail.pendingUserMessage) != nil || detail.pendingAttachments?.isEmpty == false {
            hasPendingUserMessage = true
        } else {
            hasPendingUserMessage = nil
        }
        pendingStartedAt = detail.pendingStartedAt
        worktreePath = detail.worktreePath
        sourceTag = detail.sourceTag
        rawSource = detail.rawSource
        sessionSource = detail.sessionSource
        sourceLabel = detail.sourceLabel
        parentSessionId = detail.parentSessionId
        relationshipType = detail.relationshipType
        readOnly = detail.readOnly
        isReadOnly = detail.isReadOnly
        matchType = nil
        matchPreview = nil
    }

    /// Applies the import response without dropping list metadata that the
    /// detail endpoint does not consistently return.
    func mergingImportedDetail(_ detail: SessionDetail) -> SessionSummary {
        let imported = SessionSummary(from: detail)
        return SessionSummary(
            sessionId: imported.sessionId ?? sessionId,
            title: imported.title ?? title,
            workspace: imported.workspace ?? workspace,
            model: imported.model ?? model,
            modelProvider: imported.modelProvider ?? modelProvider,
            messageCount: imported.messageCount ?? messageCount,
            createdAt: imported.createdAt ?? createdAt,
            updatedAt: imported.updatedAt ?? updatedAt,
            lastMessageAt: imported.lastMessageAt ?? lastMessageAt,
            pinned: imported.pinned ?? pinned,
            archived: imported.archived ?? archived,
            projectId: imported.projectId ?? projectId,
            profile: imported.profile ?? profile,
            inputTokens: imported.inputTokens ?? inputTokens,
            outputTokens: imported.outputTokens ?? outputTokens,
            estimatedCost: imported.estimatedCost ?? estimatedCost,
            activeStreamId: imported.activeStreamId ?? activeStreamId,
            isStreaming: imported.isStreaming ?? isStreaming,
            isCliSession: imported.isCliSession ?? isCliSession,
            userMessageCount: imported.userMessageCount ?? userMessageCount,
            hasPendingUserMessage: imported.hasPendingUserMessage ?? hasPendingUserMessage,
            pendingStartedAt: imported.pendingStartedAt ?? pendingStartedAt,
            worktreePath: imported.worktreePath ?? worktreePath,
            sourceTag: imported.sourceTag ?? sourceTag,
            rawSource: imported.rawSource ?? rawSource,
            sessionSource: imported.sessionSource ?? sessionSource,
            sourceLabel: imported.sourceLabel ?? sourceLabel,
            parentSessionId: imported.parentSessionId ?? parentSessionId,
            relationshipType: imported.relationshipType ?? relationshipType,
            readOnly: imported.readOnly ?? readOnly,
            isReadOnly: imported.isReadOnly ?? isReadOnly,
            matchType: imported.matchType ?? matchType,
            matchPreview: imported.matchPreview ?? matchPreview
        )
    }

    /// Mirrors all stored fields so local title patches preserve session-list metadata.
    /// Update this when `SessionSummary` gains a new stored property.
    func replacingTitle(with title: String) -> SessionSummary {
        SessionSummary(
            sessionId: sessionId,
            title: title,
            workspace: workspace,
            model: model,
            modelProvider: modelProvider,
            messageCount: messageCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastMessageAt: lastMessageAt,
            pinned: pinned,
            archived: archived,
            projectId: projectId,
            profile: profile,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCost,
            activeStreamId: activeStreamId,
            isStreaming: isStreaming,
            isCliSession: isCliSession,
            userMessageCount: userMessageCount,
            hasPendingUserMessage: hasPendingUserMessage,
            pendingStartedAt: pendingStartedAt,
            worktreePath: worktreePath,
            sourceTag: sourceTag,
            rawSource: rawSource,
            sessionSource: sessionSource,
            sourceLabel: sourceLabel,
            parentSessionId: parentSessionId,
            relationshipType: relationshipType,
            readOnly: readOnly,
            isReadOnly: isReadOnly,
            matchType: matchType,
            matchPreview: matchPreview
        )
    }
}

extension SessionSummary {
    private static let messagingSourceMarkers: Set<String> = [
        "discord", "email", "matrix", "slack", "telegram", "wecom", "wecom_callback", "weixin"
    ]
    private static let cliSourceMarkers: Set<String> = ["acp", "cli", "desktop", "tui"]

    /// Delegated children are identified only by an explicit source marker.
    /// Parent linkage is shared by ordinary forks and compression continuations,
    /// so it must never classify a row as a subagent on its own.
    var isDelegatedSubagentSession: Bool {
        [sourceTag, rawSource, sessionSource, sourceLabel]
            .compactMap(Self.normalizedSourceMarker)
            .contains("subagent")
    }

    /// Claude Code imports are classified only by explicit upstream source
    /// metadata. Titles, models, and read-only/CLI flags are intentionally not
    /// descriptive enough to identify this source.
    var isClaudeCodeSession: Bool {
        [sourceTag, rawSource]
            .compactMap(Self.normalizedSourceMarker)
            .contains("claude_code")
    }

    /// Delegated children are runner-owned and view-only. Upstream has also
    /// emitted both read-only spellings across row sources, so either explicit
    /// true value preserves that safety for other imported sessions.
    var isSessionReadOnly: Bool {
        isDelegatedSubagentSession || readOnly == true || isReadOnly == true
    }

    /// External sessions need the same import step hermes-webui performs before
    /// opening them. An explicit WebUI source wins over stale CLI flags left on
    /// an already-imported sidecar.
    var requiresExternalImport: Bool {
        if Self.normalizedSourceMarker(sessionSource) == "webui" { return false }
        if Self.normalizedSourceMarker(sessionSource) == "messaging" { return true }

        let markers = [rawSource, sourceTag, sourceLabel]
            .compactMap(Self.normalizedSourceMarker)
        return isCliSession == true
            || markers.contains(where: Self.messagingSourceMarkers.contains)
            || markers.contains(where: Self.cliSourceMarkers.contains)
    }

    /// The source chip shown by hermes-webui, preferring the server's label and
    /// falling back to stable brand/acronym casing for older servers.
    var sourceDisplayLabel: String? {
        guard requiresExternalImport else { return nil }

        if let label = Self.nonEmpty(sourceLabel), label.lowercased() != "webui" {
            return label
        }

        let marker = [rawSource, sourceTag, sessionSource]
            .compactMap(Self.normalizedSourceMarker)
            .first { $0 != "messaging" && $0 != "webui" }

        switch marker {
        case "cli": return "CLI"
        case "tui": return "TUI"
        case "acp": return "ACP"
        case "telegram": return "Telegram"
        case "discord": return "Discord"
        case "slack": return "Slack"
        case "email": return "Email"
        case "matrix": return "Matrix"
        case "weixin": return "WeChat"
        case "wecom": return "WeCom"
        case "wecom_callback": return "WeCom Callback"
        case "desktop": return "Desktop"
        case let marker?:
            return marker
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        case nil:
            return isCliSession == true ? "CLI" : "Messaging"
        }
    }

    var shouldAppearInSessionList: Bool {
        !isEmptySidebarPlaceholder
    }

    /// Mirrors hermes-webui's visible-sidebar safety net for just-created
    /// placeholders: hide only the known empty Untitled shape, while keeping rows
    /// with content, pending work, streaming state, or explicit user/server state.
    /// Sort timestamps such as ``lastMessageAt`` are intentionally ignored here —
    /// ``compact()`` sets them from ``updated_at`` even for zero-message sessions.
    var isEmptySidebarPlaceholder: Bool {
        guard hasPlaceholderTitle else { return false }
        guard !hasSidebarState else { return false }
        guard !hasMessageActivity else { return false }

        return (messageCount ?? 0) == 0 && (userMessageCount ?? 0) == 0
    }

    /// True when this row originates from a scheduled cron job.
    ///
    /// Mirrors hermes-webui's `is_cron_session` (`api/models.py`): a `cron`
    /// source marker (`session_source` / `source_tag` / `source_label`) or a
    /// `cron_`-prefixed session id. Tolerant — a row with no cron markers is
    /// treated as a normal session, so unknown/missing fields never hide it.
    var isCronSession: Bool {
        if let sessionId = sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            sessionId.hasPrefix("cron_") {
            return true
        }

        return [sessionSource, sourceTag, rawSource, sourceLabel]
            .compactMap(Self.normalizedSourceMarker)
            .contains("cron")
    }

    private var hasPlaceholderTitle: Bool {
        guard let normalizedTitle = Self.nonEmpty(title)?.lowercased() else { return true }
        return normalizedTitle == "untitled" || normalizedTitle == "untitled session"
    }

    private var hasSidebarState: Bool {
        pinned == true
            || isStreaming == true
            || Self.nonEmpty(activeStreamId) != nil
            || hasPendingUserMessage == true
            || pendingStartedAt != nil
            || Self.nonEmpty(worktreePath) != nil
    }

    private var hasMessageActivity: Bool {
        if let messageCount, messageCount > 0 { return true }
        if let userMessageCount, userMessageCount > 0 { return true }
        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedSourceMarker(_ value: String?) -> String? {
        nonEmpty(value)?.lowercased()
    }
}

/// Which non-standard session kinds the session list should show. Cron jobs,
/// CLI imports, Claude Code imports, and delegated subagents are controlled independently. A row
/// with unknown/missing source data remains visible as a normal session.
struct AutomatedSessionVisibility: Equatable {
    var showsCron: Bool
    var showsCli: Bool
    var showsClaudeCode: Bool
    var showsSubagents: Bool

    /// Show every kind, primarily for explicit opt-in and tests.
    static let showAll = AutomatedSessionVisibility(
        showsCron: true,
        showsCli: true,
        showsClaudeCode: true,
        showsSubagents: true
    )

    init(
        showsCron: Bool,
        showsCli: Bool,
        showsClaudeCode: Bool = true,
        showsSubagents: Bool = false
    ) {
        self.showsCron = showsCron
        self.showsCli = showsCli
        self.showsClaudeCode = showsClaudeCode
        self.showsSubagents = showsSubagents
    }

    /// Whether `session` should remain visible under these toggles.
    ///
    /// `isCliSession` is server-computed (`is_cli_session_row`, re-stamped onto
    /// every row by `_normalize_sidebar_source_flags` in `api/routes.py`); cron
    /// detection is client-side (`SessionSummary.isCronSession`).
    func shows(_ session: SessionSummary) -> Bool {
        if session.isDelegatedSubagentSession, !showsSubagents { return false }
        if session.isCronSession, !showsCron { return false }
        if session.isCliSession == true, !showsCli { return false }
        if session.isClaudeCodeSession, !showsClaudeCode { return false }
        return true
    }
}

struct SessionDetail: Decodable, Equatable, Identifiable {
    var id: String {
        if let sessionId, !sessionId.isEmpty {
            return sessionId
        }

        let titlePart = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "untitled"
        let timestamp = createdAt ?? updatedAt ?? lastMessageAt ?? 0
        return "session-\(titlePart)-\(timestamp)"
    }

    let sessionId: String?
    let title: String?
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let messageCount: Int?
    let createdAt: Double?
    let updatedAt: Double?
    let lastMessageAt: Double?
    let pinned: Bool?
    let archived: Bool?
    let projectId: String?
    let profile: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCost: Double?
    let activeStreamId: String?
    let pendingUserMessage: String?
    let pendingAttachments: [JSONValue]?
    let pendingStartedAt: Double?
    let worktreePath: String?
    let contextLength: Int?
    let thresholdTokens: Int?
    let lastPromptTokens: Int?
    let isCliSession: Bool?
    let sourceTag: String?
    let rawSource: String?
    let sessionSource: String?
    let sourceLabel: String?
    let parentSessionId: String?
    let relationshipType: String?
    let readOnly: Bool?
    let isReadOnly: Bool?
    let messages: [ChatMessage]?
    let toolCalls: [PersistedToolCall]?
    let messagesTruncated: Bool?
    let messagesOffset: Int?
    let compressionAnchorVisibleIdx: Int?
    let compressionAnchorMessageKey: CompressionAnchorMessageKey?
    let compressionAnchorSummary: String?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case title
        case workspace
        case model
        case modelProvider
        case messageCount
        case createdAt
        case updatedAt
        case lastMessageAt
        case pinned
        case archived
        case projectId
        case profile
        case inputTokens
        case outputTokens
        case estimatedCost
        case activeStreamId
        case pendingUserMessage
        case pendingAttachments
        case pendingStartedAt
        case worktreePath
        case contextLength
        case thresholdTokens
        case lastPromptTokens
        case isCliSession
        case sourceTag
        case rawSource
        case sessionSource
        case sourceLabel
        case parentSessionId
        case relationshipType
        case readOnly
        case isReadOnly
        case messages
        case toolCalls
        case messagesTruncated
        case messagesOffset
        case underscoredMessagesTruncated = "_messages_truncated"
        case underscoredMessagesOffset = "_messages_offset"
        case transformedMessagesTruncated = "_messagesTruncated"
        case transformedMessagesOffset = "_messagesOffset"
        case compressionAnchorVisibleIdx
        case compressionAnchorMessageKey
        case compressionAnchorSummary
        case snakeCasedCompressionAnchorVisibleIdx = "compression_anchor_visible_idx"
        case snakeCasedCompressionAnchorMessageKey = "compression_anchor_message_key"
        case snakeCasedCompressionAnchorSummary = "compression_anchor_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        workspace = container.decodeLossyStringIfPresent(forKey: .workspace)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        modelProvider = container.decodeLossyStringIfPresent(forKey: .modelProvider)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
        createdAt = container.decodeLossyDoubleIfPresent(forKey: .createdAt)
        updatedAt = container.decodeLossyDoubleIfPresent(forKey: .updatedAt)
        lastMessageAt = container.decodeLossyDoubleIfPresent(forKey: .lastMessageAt)
        pinned = container.decodeLossyBoolIfPresent(forKey: .pinned)
        archived = container.decodeLossyBoolIfPresent(forKey: .archived)
        projectId = container.decodeLossyStringIfPresent(forKey: .projectId)
        profile = container.decodeLossyStringIfPresent(forKey: .profile)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        estimatedCost = container.decodeLossyDoubleIfPresent(forKey: .estimatedCost)
        activeStreamId = container.decodeLossyStringIfPresent(forKey: .activeStreamId)
        pendingUserMessage = container.decodeLossyStringIfPresent(forKey: .pendingUserMessage)
        pendingAttachments = try? container.decodeIfPresent([JSONValue].self, forKey: .pendingAttachments)
        pendingStartedAt = container.decodeLossyDoubleIfPresent(forKey: .pendingStartedAt)
        worktreePath = container.decodeLossyStringIfPresent(forKey: .worktreePath)
        contextLength = container.decodeLossyIntIfPresent(forKey: .contextLength)
        thresholdTokens = container.decodeLossyIntIfPresent(forKey: .thresholdTokens)
        lastPromptTokens = container.decodeLossyIntIfPresent(forKey: .lastPromptTokens)
        isCliSession = container.decodeLossyBoolIfPresent(forKey: .isCliSession)
        sourceTag = container.decodeLossyStringIfPresent(forKey: .sourceTag)
        rawSource = container.decodeLossyStringIfPresent(forKey: .rawSource)
        sessionSource = container.decodeLossyStringIfPresent(forKey: .sessionSource)
        sourceLabel = container.decodeLossyStringIfPresent(forKey: .sourceLabel)
        parentSessionId = container.decodeLossyStringIfPresent(forKey: .parentSessionId)
        relationshipType = container.decodeLossyStringIfPresent(forKey: .relationshipType)
        readOnly = container.decodeLossyBoolIfPresent(forKey: .readOnly)
        isReadOnly = container.decodeLossyBoolIfPresent(forKey: .isReadOnly)
        messages = Self.decodeMessagesTolerantly(from: container)
        toolCalls = Self.decodeToolCallsTolerantly(from: container)
        messagesTruncated = container.decodeLossyBoolIfPresent(forKey: .underscoredMessagesTruncated)
            ?? container.decodeLossyBoolIfPresent(forKey: .transformedMessagesTruncated)
            ?? container.decodeLossyBoolIfPresent(forKey: .messagesTruncated)
        messagesOffset = container.decodeLossyIntIfPresent(forKey: .underscoredMessagesOffset)
            ?? container.decodeLossyIntIfPresent(forKey: .transformedMessagesOffset)
            ?? container.decodeLossyIntIfPresent(forKey: .messagesOffset)
        compressionAnchorVisibleIdx = container.decodeLossyIntIfPresent(forKey: .compressionAnchorVisibleIdx)
            ?? container.decodeLossyIntIfPresent(forKey: .snakeCasedCompressionAnchorVisibleIdx)
        compressionAnchorMessageKey = ((try? container.decodeIfPresent(
            CompressionAnchorMessageKey.self,
            forKey: .compressionAnchorMessageKey
        )) ?? nil)
            ?? ((try? container.decodeIfPresent(
                CompressionAnchorMessageKey.self,
                forKey: .snakeCasedCompressionAnchorMessageKey
            )) ?? nil)
        compressionAnchorSummary = container.decodeLossyStringIfPresent(forKey: .compressionAnchorSummary)
            ?? container.decodeLossyStringIfPresent(forKey: .snakeCasedCompressionAnchorSummary)
    }

    private static func decodeMessagesTolerantly(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [ChatMessage]? {
        if let direct = try? container.decodeIfPresent([ChatMessage].self, forKey: .messages) {
            return direct
        }

        guard let values = try? container.decodeIfPresent([JSONValue].self, forKey: .messages) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        return values.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(ChatMessage.self, from: data)
        }
    }

    private static func decodeToolCallsTolerantly(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [PersistedToolCall]? {
        if let direct = try? container.decodeIfPresent([PersistedToolCall].self, forKey: .toolCalls) {
            return direct
        }

        guard let values = try? container.decodeIfPresent([JSONValue].self, forKey: .toolCalls) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        return values.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? decoder.decode(PersistedToolCall.self, from: data)
        }
    }
}

/// Anchor key the server builds in `_anchor_message_key` (`api/routes.py`):
/// role, optional timestamp, first 160 chars of whitespace-normalized text,
/// and attachment count of the last visible message after compaction.
struct CompressionAnchorMessageKey: Decodable, Equatable {
    let role: String?
    let ts: Double?
    let text: String?
    let attachments: Int?

    init(role: String?, ts: Double?, text: String?, attachments: Int?) {
        self.role = role
        self.ts = ts
        self.text = text
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case role
        case ts
        case text
        case attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = container.decodeLossyStringIfPresent(forKey: .role)
        ts = container.decodeLossyDoubleIfPresent(forKey: .ts)
        text = container.decodeLossyStringIfPresent(forKey: .text)
        attachments = container.decodeLossyIntIfPresent(forKey: .attachments)
    }
}
