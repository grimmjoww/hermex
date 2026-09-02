import Foundation
import Observation

@MainActor
@Observable
final class TaskDetailViewModel {
    private(set) var job: CronJob
    private(set) var runningElapsed: Double?

    private(set) var outputs: [CronOutputItem] = []
    private(set) var runHistory: [CronRunEntry] = []
    private(set) var runHistoryTotal: Int?
    /// Number of server records already consumed across pages. Server paging
    /// is positional, so the next request's offset must track fetched records —
    /// not the deduplicated display list, or a repeated filename across a page
    /// boundary would re-request an earlier offset forever.
    private(set) var consumedRunCount = 0
    private(set) var isLoadingHistory = false
    private(set) var historyErrorMessage: String?
    private(set) var loadedRunDetail: CronRunDetailResponse?
    private(set) var isLoadingRunDetail = false
    private(set) var runDetailErrorMessage: String?
    /// The run whose detail request is currently in flight; responses (and
    /// errors) for any other run are discarded so a slow earlier request can
    /// never overwrite a newer selection.
    private var inFlightRunDetailFilename: String?
    /// Server-provided deliver targets; `nil` while unknown or when the
    /// endpoint is unavailable (the editor then falls back to free text).
    private(set) var deliveryOptions: [CronDeliveryOption]?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var lastMutation: CronJobListMutation?

    private let client: APIClient

    private static let runHistoryPageSize = 50

    init(job: CronJob, runningElapsed: Double?, server: URL, client: APIClient? = nil) {
        self.job = job
        self.runningElapsed = runningElapsed
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        guard let jobID = job.jobId else {
            errorMessage = String(localized: "Missing job identifier.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        // Optional endpoint: failure must not break the detail view, and a
        // nil result keeps the editor's free-text deliver fallback.
        async let deliveryOptionsResponse = try? client.cronDeliveryOptions()

        do {
            let response = try await client.cronOutput(jobID: jobID, limit: 5)
            outputs = response.outputs ?? []
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }

        deliveryOptions = await deliveryOptionsResponse?.platforms
    }

    /// Loads the first page of run history. History is an optional enhancement:
    /// a failure never blocks the detail screen (the recent-output section is
    /// the primary content), it only shows a small inline error.
    func loadRunHistory() async {
        guard let jobID = job.jobId else { return }

        isLoadingHistory = true
        historyErrorMessage = nil
        defer { isLoadingHistory = false }

        do {
            let response = try await client.cronRunHistory(jobID: jobID, offset: 0, limit: Self.runHistoryPageSize)
            runHistory = response.runs ?? []
            consumedRunCount = runHistory.count
            runHistoryTotal = response.total
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    /// Appends the next page of runs; `true` when a request was made. The
    /// paging offset counts server records consumed (including duplicates the
    /// display list drops), so it always advances past the last fetched page.
    func loadMoreRunHistory() async -> Bool {
        guard let jobID = job.jobId else { return false }

        let nextOffset = consumedRunCount
        guard canLoadMoreRunHistory, nextOffset > 0 else { return false }

        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let response = try await client.cronRunHistory(jobID: jobID, offset: nextOffset, limit: Self.runHistoryPageSize)
            runHistory.append(contentsOf: response.runs ?? [])
            consumedRunCount = nextOffset + (response.runs?.count ?? 0)
            runHistory = deduplicatedRunHistory()
            runHistoryTotal = response.total
            return true
        } catch {
            historyErrorMessage = error.localizedDescription
            return false
        }
    }

    var canLoadMoreRunHistory: Bool {
        guard let total = runHistoryTotal else { return false }
        return consumedRunCount < total
    }

    /// Server returns runs newest-first; dedupe defensively by filename so a
    /// page boundary can never render a row twice.
    private func deduplicatedRunHistory() -> [CronRunEntry] {
        var seen = Set<String>()
        return runHistory.filter { entry in
            let key = entry.filename ?? entry.id
            return seen.insert(key).inserted
        }
    }

    /// Loads the full content of one past run for the detail sheet. Tracks the
    /// in-flight filename so a slow response for an earlier selection (or an
    /// error arriving after the user moved on) can never clobber the newer
    /// selection's state. Cancellation is not a user-facing failure.
    func loadRunDetail(filename: String) async {
        guard let jobID = job.jobId, !filename.isEmpty else {
            runDetailErrorMessage = String(localized: "Missing run identifier.")
            return
        }

        isLoadingRunDetail = true
        loadedRunDetail = nil
        runDetailErrorMessage = nil
        inFlightRunDetailFilename = filename

        defer {
            // Only wind down the loading flag if this request is still the
            // active one; a superseded request finishing late must not clear
            // the newer request's spinner.
            if inFlightRunDetailFilename == filename {
                isLoadingRunDetail = false
            }
        }

        do {
            let response = try await client.cronRunDetail(jobID: jobID, filename: filename)
            guard inFlightRunDetailFilename == filename else { return }
            loadedRunDetail = response
        } catch is CancellationError {
            return
        } catch {
            guard inFlightRunDetailFilename == filename else { return }
            runDetailErrorMessage = error.localizedDescription
        }
    }

    func clearRunDetail() {
        inFlightRunDetailFilename = nil
        isLoadingRunDetail = false
        loadedRunDetail = nil
        runDetailErrorMessage = nil
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    func runNow() async -> Bool {
        let success = await mutateJob { jobID in
            try await client.runCron(jobID: jobID)
        }
        if success {
            runningElapsed = 0
        }
        return success
    }

    func pause(reason: String? = nil) async -> Bool {
        let success = await mutateJob { jobID in
            try await client.pauseCron(jobID: jobID, reason: reason)
        }
        if success {
            runningElapsed = nil
        }
        return success
    }

    func resume() async -> Bool {
        return await mutateJob { jobID in
            try await client.resumeCron(jobID: jobID)
        }
    }

    func update(from draft: CronJobEditorDraft) async -> Bool {
        guard draft.validationMessage == nil else {
            actionErrorMessage = draft.validationMessage
            return false
        }

        return await mutateJob { jobID in
            try await client.updateCron(
                jobID: jobID,
                prompt: draft.trimmedPrompt,
                schedule: draft.trimmedSchedule,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                deliver: draft.deliver.trimmingCharacters(in: .whitespacesAndNewlines),
                skills: draft.skills,
                model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: draft.provider.trimmingCharacters(in: .whitespacesAndNewlines),
                profile: draft.profile.trimmingCharacters(in: .whitespacesAndNewlines),
                toastNotifications: draft.toastNotifications
            )
        }
    }

    func delete() async -> Bool {
        guard let jobID = job.jobId else {
            actionErrorMessage = String(localized: "Missing job identifier.")
            return false
        }

        isMutating = true
        actionErrorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isMutating = false }

        do {
            let response = try await client.deleteCron(jobID: jobID)
            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not delete task.")
                return false
            }

            lastMutation = .delete(jobID: jobID)
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func mutateJob(
        action: (String) async throws -> CronMutationResponse
    ) async -> Bool {
        guard let jobID = job.jobId else {
            actionErrorMessage = String(localized: "Missing job identifier.")
            return false
        }

        isMutating = true
        actionErrorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isMutating = false }

        do {
            let response = try await action(jobID)
            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not update task.")
                return false
            }

            if let updatedJob = response.job {
                job = updatedJob
                lastMutation = .upsert(updatedJob)
            }
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }
}
