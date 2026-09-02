import SwiftUI

struct TaskDetailView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    let onMutation: (CronJobListMutation) -> Void

    @State private var viewModel: TaskDetailViewModel
    @State private var isPresentingEditTask = false
    @State private var isConfirmingDelete = false
    @State private var selectedRun: CronRunEntry?
    @Environment(\.dismiss) private var dismiss

    init(
        job: CronJob,
        runningElapsed: Double?,
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        onMutation: @escaping (CronJobListMutation) -> Void = { _ in }
    ) {
        self.server = server
        self.onAPIError = onAPIError
        self.onMutation = onMutation
        _viewModel = State(initialValue: TaskDetailViewModel(job: job, runningElapsed: runningElapsed, server: server))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                actionStatusSection
                metadataSection
                runHistorySection

                if viewModel.isLoading && viewModel.outputs.isEmpty {
                    ProgressView("Loading output...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else if let errorMessage = viewModel.errorMessage, viewModel.outputs.isEmpty {
                    ContentUnavailableView {
                        Label("Could Not Load Output", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadOutput() }
                        }
                    }
                    .padding(.top, 24)
                } else if viewModel.outputs.isEmpty {
                    ContentUnavailableView {
                        Label("No Recent Output", systemImage: "doc.text")
                    } description: {
                        Text("This task has not produced any output yet.")
                    }
                    .padding(.top, 24)
                } else {
                    outputsSection
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.job.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await loadOutput() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)

                Menu {
                    Button {
                        Task { await runNow() }
                    } label: {
                        Label("Run Now", systemImage: "play.fill")
                    }
                    .disabled(isActionDisabled)

                    Button {
                        Task { await togglePauseResume() }
                    } label: {
                        Label(pauseResumeTitle, systemImage: pauseResumeSystemImage)
                    }
                    .disabled(isActionDisabled)

                    Button {
                        viewModel.clearActionError()
                        isPresentingEditTask = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(isActionDisabled)

                    Divider()

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(isActionDisabled)
                } label: {
                    Label("Task Actions", systemImage: "ellipsis.circle")
                }
                .disabled(viewModel.isMutating)
            }
        }
        .sheet(isPresented: $isPresentingEditTask) {
            CronJobEditorSheet(
                title: String(localized: "Edit Task"),
                draft: CronJobEditorDraft(job: viewModel.job),
                saveTitle: String(localized: "Save"),
                isSaving: viewModel.isMutating,
                errorMessage: viewModel.actionErrorMessage,
                deliveryOptions: viewModel.deliveryOptions
            ) { draft in
                let didUpdate = await viewModel.update(from: draft)
                handleActionResult(didUpdate)
                return didUpdate
            }
        }
        .sheet(item: $selectedRun, onDismiss: { viewModel.clearRunDetail() }) { run in
            CronRunDetailSheet(
                run: run,
                isLoading: viewModel.isLoadingRunDetail,
                detail: viewModel.loadedRunDetail,
                errorMessage: viewModel.runDetailErrorMessage,
                onRetry: {
                    Task {
                        await viewModel.loadRunDetail(filename: run.filename ?? "")
                    }
                }
            )
            .task(id: run.id) {
                await viewModel.loadRunDetail(filename: run.filename ?? "")
            }
        }
        .alert("Delete Task?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await deleteTask() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the scheduled task from the Hermes server.")
        }
        .task {
            await loadOutput()
            await loadRunHistory()
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(viewModel.job.displayName)
                    .font(.title2.bold())
                    .lineLimit(2)

                Spacer(minLength: 8)

                StatusBadge(
                    text: viewModel.runningElapsed == nil ? viewModel.job.status.label : String(localized: "Running"),
                    color: statusColor
                )
            }

            if let prompt = viewModel.job.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
        }
    }

    @ViewBuilder
    private var actionStatusSection: some View {
        if viewModel.isMutating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Updating task...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let actionErrorMessage = viewModel.actionErrorMessage {
            Text(actionErrorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            CronJobMetadataRow(
                title: String(localized: "Schedule"),
                value: viewModel.job.scheduleText ?? String(localized: "Not available")
            )

            CronJobMetadataRow(
                title: String(localized: "Next"),
                value: viewModel.job.nextRunAt?.formatted ?? String(localized: "Not available")
            )

            CronJobMetadataRow(
                title: String(localized: "Last"),
                value: viewModel.job.lastRunAt?.formatted ?? String(localized: "Never")
            )

            if let runningElapsed = viewModel.runningElapsed {
                CronJobMetadataRow(
                    title: String(localized: "Elapsed"),
                    value: elapsedText(runningElapsed)
                )
            }

            CronJobMetadataRow(
                title: String(localized: "Deliver"),
                value: viewModel.job.deliver ?? "local"
            )

            if let model = viewModel.job.model, !model.isEmpty {
                CronJobMetadataRow(title: String(localized: "Model"), value: model)
            }

            if let provider = viewModel.job.provider, !provider.isEmpty {
                CronJobMetadataRow(title: String(localized: "Provider"), value: provider)
            }

            if let profile = viewModel.job.profile, !profile.isEmpty {
                CronJobMetadataRow(title: String(localized: "Profile"), value: profile)
            }

            if let toastNotifications = viewModel.job.toastNotifications {
                CronJobMetadataRow(title: String(localized: "Toasts"), value: toastNotifications ? String(localized: "On") : String(localized: "Off"))
            }

            if let skills = viewModel.job.skills, !skills.isEmpty {
                CronJobMetadataRow(title: String(localized: "Skills"), value: skills.joined(separator: ", "))
            }

            if let error = viewModel.job.lastError ?? viewModel.job.lastDeliveryError, !error.isEmpty {
                CronJobMetadataRow(title: String(localized: "Error"), value: error)
                    .foregroundStyle(.red)
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var runHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Run History")
                    .font(.headline)
                Spacer()
                if let total = viewModel.runHistoryTotal {
                    Text("\(total) total")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isLoadingHistory && viewModel.runHistory.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if let historyError = viewModel.historyErrorMessage, viewModel.runHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(historyError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await loadRunHistory() }
                    }
                    .font(.footnote)
                }
            } else if viewModel.runHistory.isEmpty {
                Text("No Past Runs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.runHistory) { run in
                    if run.addressable {
                        Button {
                            selectedRun = run
                        } label: {
                            CronRunHistoryRow(run: run)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // No filename means the server cannot serve this
                        // run's content, so the row is display-only.
                        CronRunHistoryRow(run: run)
                    }
                }

                if viewModel.canLoadMoreRunHistory {
                    Button {
                        Task { _ = await viewModel.loadMoreRunHistory() }
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isLoadingHistory {
                                ProgressView()
                            }
                            Text("Load More")
                        }
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isLoadingHistory)
                }
            }
        }
    }

    private func loadRunHistory() async {
        await viewModel.loadRunHistory()
    }

    @ViewBuilder
    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Output")
                .font(.headline)

            ForEach(viewModel.outputs) { output in
                VStack(alignment: .leading, spacing: 8) {
                    Text(output.filename ?? String(localized: "Untitled"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let content = output.content, !content.isEmpty {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Text("Empty output")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var statusColor: Color {
        if viewModel.runningElapsed != nil {
            return .blue
        }

        switch viewModel.job.status {
        case .active:
            return .green
        case .paused, .off:
            return .orange
        case .error:
            return .red
        case .needsAttention:
            return .yellow
        }
    }

    private var isActionDisabled: Bool {
        viewModel.isMutating || viewModel.job.jobId == nil
    }

    private var pauseResumeTitle: String {
        shouldResume ? String(localized: "Resume") : String(localized: "Pause")
    }

    private var pauseResumeSystemImage: String {
        shouldResume ? "play.circle" : "pause.circle"
    }

    private var shouldResume: Bool {
        viewModel.job.status == .paused || viewModel.job.status == .off
    }

    private func elapsedText(_ elapsed: Double) -> String {
        if elapsed < 60 {
            return "\(Int(elapsed.rounded()))s"
        }

        let minutes = Int(elapsed / 60)
        let seconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }

    private func loadOutput() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func runNow() async {
        let didRun = await viewModel.runNow()
        handleActionResult(didRun)
    }

    private func togglePauseResume() async {
        let didMutate: Bool
        if shouldResume {
            didMutate = await viewModel.resume()
        } else {
            didMutate = await viewModel.pause()
        }
        handleActionResult(didMutate)
    }

    private func deleteTask() async {
        let didDelete = await viewModel.delete()
        handleActionResult(didDelete)

        if didDelete {
            dismiss()
        }
    }

    private func handleActionResult(_ success: Bool) {
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        guard success, let mutation = viewModel.lastMutation else {
            return
        }

        onMutation(mutation)
    }
}

/// One row in the Run History list: filename, date, size, and usage chips.
struct CronRunHistoryRow: View {
    let run: CronRunEntry

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.filename ?? String(localized: "Untitled"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                if let date = run.modified?.date {
                    Text(date, style: .date)
                    Text(date, style: .time)
                }

                if let size = run.size {
                    Text(Self.byteFormatter.string(fromByteCount: Int64(size)))
                }

                if let usage = run.usage {
                    if !usage.chipText.isEmpty {
                        Text(usage.chipText)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

extension CronRunEntry {
    /// Whether this run can be opened: a filename is required to fetch its
    /// content, so filename-less rows render display-only instead of opening
    /// a detail sheet that can never load.
    var addressable: Bool {
        !(filename?.isEmpty ?? true)
    }
}

extension CronRunUsage {
    /// Compact one-line summary for the history row chips ("model · 2.3s · $0.0123").
    var chipText: String {
        var parts: [String] = []
        if let durationSeconds, durationSeconds > 0 {
            if durationSeconds < 60 {
                parts.append(String(format: "%.1fs", durationSeconds))
            } else {
                parts.append(String(format: "%.1fm", durationSeconds / 60))
            }
        }
        if let estimatedCostUsd {
            parts.append(String(format: "$%.4f", estimatedCostUsd))
        }
        return parts.joined(separator: " · ")
    }
}

/// Tap-through from a history row: full output of one past run.
struct CronRunDetailSheet: View {
    let run: CronRunEntry
    let isLoading: Bool
    let detail: CronRunDetailResponse?
    let errorMessage: String?
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "Loading run..."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, detail == nil {
                    ContentUnavailableView {
                        Label("Could Not Load Run", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            onRetry()
                        }
                    }
                } else if let detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let content = detail.content, !content.isEmpty {
                                Text(content)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                Text("Empty output")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(Text(run.filename ?? String(localized: "Untitled")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
