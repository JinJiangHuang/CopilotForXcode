import ActiveApplicationMonitor
import AppKit
import AsyncAlgorithms
import AXExtension
import Combine
import Foundation
import Logger
import Preferences
import QuartzCore
import Workspace
import XcodeInspector

public actor RealtimeSuggestionController {
    private var cancellable: Set<AnyCancellable> = []
    private var inflightPrefetchTask: Task<Void, Error>?
    private var editorObservationTask: Task<Void, Error>?
    private var sourceEditor: SourceEditor?

    init() {}

    deinit {
        cancellable.forEach { $0.cancel() }
        inflightPrefetchTask?.cancel()
        editorObservationTask?.cancel()
    }

    nonisolated
    func start() {
        Task { await observeXcodeChange() }
    }

    private func observeXcodeChange() {
        cancellable.forEach { $0.cancel() }

        XcodeInspector.shared.$focusedEditor
            .sink { [weak self] editor in
                guard let self else { return }
                Task {
                    guard let editor else { return }
                    await self.handleFocusElementChange(editor)
                }
            }.store(in: &cancellable)
    }

    private func handleFocusElementChange(_ sourceEditor: SourceEditor) {
        Task { // Notify suggestion service for open file.
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let fileURL = XcodeInspector.shared.realtimeActiveDocumentURL else { return }
            _ = try await Service.shared.workspacePool
                .fetchOrCreateWorkspaceAndFilespace(fileURL: fileURL)
        }

        self.sourceEditor = sourceEditor

        let notificationsFromEditor = sourceEditor.axNotifications

        editorObservationTask?.cancel()
        editorObservationTask = nil

        editorObservationTask = Task { [weak self] in
            if let fileURL = XcodeInspector.shared.realtimeActiveDocumentURL {
                await PseudoCommandHandler().invalidateRealtimeSuggestionsIfNeeded(
                    fileURL: fileURL,
                    sourceEditor: sourceEditor
                )
            }

            let valueChange = notificationsFromEditor.filter { $0.kind == .valueChanged }
            let selectedTextChanged = notificationsFromEditor
                .filter { $0.kind == .selectedTextChanged }

            await withTaskGroup(of: Void.self) { [weak self] group in
                group.addTask { [weak self] in
                    let handler = { [weak self] in
                        guard let self else { return }
                        await cancelInFlightTasks()
                        await self.triggerPrefetchDebounced()
                        await self.notifyEditingFileChange(editor: sourceEditor.element)
                    }

                    if #available(macOS 13.0, *) {
                        for await _ in valueChange.throttle(for: .milliseconds(200)) {
                            if Task.isCancelled { return }
                            await handler()
                        }
                    } else {
                        for await _ in valueChange {
                            if Task.isCancelled { return }
                            await handler()
                        }
                    }
                }
                group.addTask {
                    let handler = {
                        guard let fileURL = XcodeInspector.shared.activeDocumentURL else { return }
                        await PseudoCommandHandler().invalidateRealtimeSuggestionsIfNeeded(
                            fileURL: fileURL,
                            sourceEditor: sourceEditor
                        )
                    }

                    if #available(macOS 13.0, *) {
                        for await _ in selectedTextChanged.throttle(for: .milliseconds(200)) {
                            if Task.isCancelled { return }
                            await handler()
                        }
                    } else {
                        for await _ in selectedTextChanged {
                            if Task.isCancelled { return }
                            await handler()
                        }
                    }
                }

                await group.waitForAll()
            }
        }

        Task { @WorkspaceActor in // Get cache ready for real-time suggestions.
            guard UserDefaults.shared.value(for: \.preCacheOnFileOpen) else { return }
            guard let fileURL = XcodeInspector.shared.realtimeActiveDocumentURL else { return }
            let (_, filespace) = try await Service.shared.workspacePool
                .fetchOrCreateWorkspaceAndFilespace(fileURL: fileURL)

            if filespace.codeMetadata.uti == nil {
                Logger.service.info("Generate cache for file.")
                // avoid the command get called twice
                filespace.codeMetadata.uti = ""
                do {
                    try await XcodeInspector.shared.latestActiveXcode?
                        .triggerCopilotCommand(name: "Real-time Suggestions")
                } catch {
                    if filespace.codeMetadata.uti?.isEmpty ?? true {
                        filespace.codeMetadata.uti = nil
                    }
                }
            }
        }
    }

    func triggerPrefetchDebounced(force: Bool = false) {
        inflightPrefetchTask = Task(priority: .utility) { @WorkspaceActor in
            try? await Task.sleep(nanoseconds: UInt64(
                max(UserDefaults.shared.value(for: \.realtimeSuggestionDebounce), 0.15)
                    * 1_000_000_000
            ))

            if Task.isCancelled { return }

            guard UserDefaults.shared.value(for: \.realtimeSuggestionToggle)
            else { return }

            if UserDefaults.shared.value(for: \.disableSuggestionFeatureGlobally),
               let fileURL = XcodeInspector.shared.activeDocumentURL,
               let (workspace, _) = try? await Service.shared.workspacePool
               .fetchOrCreateWorkspaceAndFilespace(fileURL: fileURL)
            {
                let isEnabled = workspace.isSuggestionFeatureEnabled
                if !isEnabled { return }
            }
            if Task.isCancelled { return }

            // So the editor won't be blocked (after information are cached)!
            await PseudoCommandHandler().generateRealtimeSuggestions(sourceEditor: sourceEditor)
        }
    }

    func cancelInFlightTasks(excluding: Task<Void, Never>? = nil) async {
        inflightPrefetchTask?.cancel()

        // cancel in-flight tasks
        await withTaskGroup(of: Void.self) { group in
            for (_, workspace) in Service.shared.workspacePool.workspaces {
                group.addTask {
                    await workspace.cancelInFlightRealtimeSuggestionRequests()
                }
            }
        }
    }

    /// This method will still return true if the completion panel is hidden by esc.
    /// Looks like the Xcode will keep the panel around until content is changed,
    /// not sure how to observe that it's hidden.
    func isCompletionPanelPresenting() -> Bool {
        guard let activeXcode = XcodeInspector.shared.activeXcode else { return false }
        let application = activeXcode.appElement
        do {
            return try application.focusedWindow()?
                .child(identifier: "_XC_COMPLETION_TABLE_") != nil
        } catch {
            return false
        }
    }

    func notifyEditingFileChange(editor: AXUIElement) async {
        guard let fileURL = XcodeInspector.shared.activeDocumentURL,
              let (workspace, _) = try? await Service.shared.workspacePool
              .fetchOrCreateWorkspaceAndFilespace(fileURL: fileURL)
        else { return }
        do {
            try await workspace.didUpdateFilespace(fileURL: fileURL, content: editor.value())
        } catch {
            return
        }
    }
}

