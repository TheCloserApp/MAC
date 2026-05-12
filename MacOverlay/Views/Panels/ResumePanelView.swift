import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ResumePanelView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var showResumeLibrary = false
    @State private var editingResumeID: UUID? = nil
    @State private var draftResumeName = ""
    @State private var importError: String? = nil
    @State private var isDropTargeted = false
    @State private var tab: Tab = .build
    @State private var viewingGenerationID: UUID? = nil

    enum Tab: Hashable { case build, history }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            if tab == .build {
                buildTabContent
            } else {
                historyTabContent
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.system(size: 22, weight: .medium))
                            Text("Drop PDF / DOCX / RTF / TXT to import")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .allowsHitTesting(false)
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func importErrorBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
            Text(msg)
                .font(.caption2)
                .foregroundColor(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { importError = nil } label: {
                Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Drop + upload

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { importFrom(url: url) }
        }
        return true
    }

    private func openUploadPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
                                     .rtf, .plainText,
                                     UTType(filenameExtension: "md") ?? .plainText]
        panel.prompt = "Import"
        panel.message = "Pick a PDF, DOCX, RTF, TXT or MD resume"
        if panel.runModal() == .OK, let url = panel.url {
            importFrom(url: url)
        }
    }

    private func importFrom(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ResumeImporter.supportedExtensions.contains(ext) else {
            importError = "Unsupported file type: .\(ext)"
            return
        }
        do {
            let source = try ResumeImporter.importFileWithSource(url: url)
            let name = ResumeImporter.suggestedName(for: url)
            let preset = vm.resumeStore.add(
                name: name.isEmpty ? "Imported Resume" : name,
                content: source.text,
                originalDOCX: source.originalDOCX,
                originalFilename: url.lastPathComponent
            )
            vm.resumeStore.activePresetID = preset.id
            importError = nil
            // Auto-open the library so the user sees the new entry
            showResumeLibrary = true
        } catch {
            importError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var resumePicker: some View {
        let store = vm.resumeStore
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if store.presets.isEmpty {
                Text("No saved resumes yet")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Menu {
                    ForEach(store.presets) { p in
                        Button {
                            store.activePresetID = p.id
                        } label: {
                            HStack {
                                Text(p.name)
                                if p.id == store.activePresetID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.activePreset?.name ?? "Select resume")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundColor(.primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            Button { openUploadPanel() } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Upload PDF / DOCX / RTF / TXT")

            Button {
                showResumeLibrary.toggle()
            } label: {
                Image(systemName: showResumeLibrary ? "list.bullet.circle.fill" : "list.bullet.circle")
                    .font(.system(size: 12))
                    .foregroundColor(showResumeLibrary ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Manage resumes")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var resumeLibrarySection: some View {
        let store = vm.resumeStore
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Resumes")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button { openUploadPanel() } label: {
                    Label("Upload", systemImage: "arrow.up.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Import PDF, DOCX, RTF, TXT or MD")

                Button {
                    let fresh = store.add(name: "Untitled Resume", content: "")
                    editingResumeID = fresh.id
                    draftResumeName = fresh.name
                    store.activePresetID = fresh.id
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 12)

            VStack(spacing: 3) {
                ForEach(store.presets) { p in
                    resumeLibraryRow(p)
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private func resumeLibraryRow(_ p: ResumePreset) -> some View {
        let isActive = p.id == vm.resumeStore.activePresetID
        let isEditing = p.id == editingResumeID
        HStack(spacing: 8) {
            if isEditing {
                TextField("Resume name", text: $draftResumeName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { finishRename(p) }
                Button("Save") { finishRename(p) }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            } else {
                Button {
                    vm.resumeStore.activePresetID = p.id
                } label: {
                    HStack {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 11))
                            .foregroundColor(isActive ? .accentColor : .secondary)
                        Text(p.name)
                            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    editingResumeID = p.id
                    draftResumeName = p.name
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    vm.resumeStore.delete(id: p.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(vm.resumeStore.presets.count <= 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func finishRename(_ p: ResumePreset) {
        var updated = p
        updated.name = draftResumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.name.isEmpty { updated.name = "Untitled Resume" }
        vm.resumeStore.update(updated)
        editingResumeID = nil
        draftResumeName = ""
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Resume")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(.primary)
            Text("Tailor a resume to any job description")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var tabBar: some View {
        let count = vm.resumeStore.generations.count
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabChip("Build", isActive: tab == .build) { tab = .build }
                tabChip(count > 0 ? "Generations (\(count))" : "Generations",
                        isActive: tab == .history) { tab = .history }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    private func tabChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(Design.Motion.fast) { action() } }) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .primary : .secondary.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(isActive ? Color.white.opacity(0.10) : .clear)
                )
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? Color.white.opacity(0.18) : Color.white.opacity(0.08),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var buildTabContent: some View {
        resumePicker
        if showResumeLibrary {
            resumeLibrarySection
        } else {
            resumeBaseSection
        }
        if let err = importError { importErrorBanner(err) }
        jdSection
        generateButton
        scoreSection
        outputSection
    }

    @ViewBuilder
    private var historyTabContent: some View {
        if let viewingID = viewingGenerationID,
           let g = vm.resumeStore.generations.first(where: { $0.id == viewingID }) {
            GenerationDetailView(generation: g,
                                 onBack: { viewingGenerationID = nil },
                                 onDelete: {
                                     vm.resumeStore.deleteGeneration(id: g.id)
                                     viewingGenerationID = nil
                                 })
        } else {
            generationsList
        }
    }

    @ViewBuilder
    private var generationsList: some View {
        if vm.resumeStore.generations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No generations yet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Generate a tailored resume from the Build tab and it'll show up here with a before/after score.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(vm.resumeStore.generations) { g in
                        GenerationRow(
                            generation: g,
                            onOpen: { viewingGenerationID = g.id },
                            onDelete: { vm.resumeStore.deleteGeneration(id: g.id) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var resumeBaseSection: some View {
        let store = vm.resumeStore
        let activeName = store.activePreset?.name ?? "Resume"
        let activeContent = store.activePreset?.content ?? ""
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(activeName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if !activeContent.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                Spacer()
                Text("Edits auto-save to this preset")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)

            if let preset = store.activePreset {
                ResumeInputSection(
                    placeholder: "Paste your resume here — it will be saved to \"\(preset.name)\"",
                    text: Binding(
                        get: { store.activePreset?.content ?? "" },
                        set: { newValue in
                            var updated = preset
                            updated.content = newValue
                            store.update(updated)
                        }
                    ),
                    height: preset.content.isEmpty ? 80 : 44
                )
            } else {
                Button("Create your first resume") {
                    let fresh = store.add(name: "My Resume", content: "")
                    store.activePresetID = fresh.id
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var jdSection: some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Job Description")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Ctrl+Opt+R — paste clipboard JD & generate")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            ResumeInputSection(
                placeholder: "Paste job description here, or copy it and press Ctrl+Opt+R from anywhere",
                text: $vm.resumeJD,
                height: 80
            )
        }
        .padding(.top, 4)
    }

    private var generateButton: some View {
        let disabled = vm.resumeJD.isEmpty || vm.currentResumeText.isEmpty
            || vm.isGeneratingResume || vm.apiKey.isEmpty
        return HStack {
            Spacer()
            Button { vm.generateResume() } label: {
                HStack(spacing: 6) {
                    if vm.isGeneratingResume { ProgressView().scaleEffect(0.65) }
                    Text(vm.isGeneratingResume ? "Generating…" : "Generate Resume")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(disabled ? Color.secondary : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var scoreSection: some View {
        if vm.isScoringResume || vm.resumeScore != nil {
            Divider()
            if vm.isScoringResume {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text("Scoring…").font(.system(size: 11)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else if let sc = vm.resumeScore {
                ResumeScoreRow(score: sc) { vm.resumeScore = nil }
            }
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if !vm.resumeOutput.isEmpty || vm.isGeneratingResume {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Generated Resume")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !vm.resumeOutput.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(vm.resumeOutput, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if vm.isGeneratingResume && vm.resumeOutput.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text(vm.resumeGenerationStatus.isEmpty ? "Generating…" : vm.resumeGenerationStatus)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .animation(.easeInOut(duration: 0.2), value: vm.resumeGenerationStatus)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                } else {
                    ScrollView {
                        Text(vm.resumeOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(minHeight: 100, maxHeight: 200)

                    if let url = vm.resumeFileURL {
                        ResumeDragBadge(url: url)
                        Button {
                            ResumePreviewHelper.shared.show(url: url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "eye").font(.system(size: 11))
                                Text("Preview").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }
}

// MARK: - Subviews

private struct ResumeInputSection: View {
    let placeholder: String
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 11))
                .frame(height: height)
                .scrollContentBackground(.hidden)
        }
        .padding(4)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
    }
}

struct ResumeScoreRow: View {
    let score: ResumeScore
    var onDismiss: () -> Void = {}

    private var scoreColor: Color {
        score.score >= 80 ? .green : score.score >= 60 ? .yellow : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(scoreColor.opacity(0.2), lineWidth: 3)
                        .frame(width: 36, height: 36)
                    Circle()
                        .trim(from: 0, to: CGFloat(score.score) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 36, height: 36)
                        .rotationEffect(.degrees(-90))
                    Text("\(score.score)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(scoreColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(score.verdict)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                    Text(score.recommendation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !score.missing.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Text("Missing:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ForEach(score.missing, id: \.self) { kw in
                            Text(kw)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.1))
                                .foregroundColor(.red)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct ResumeDragBadge: View {
    let url: URL

    var body: some View {
        ZStack {
            FileDragView(fileURL: url)
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text("Drag into browser to upload")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "cursorarrow.and.square.on.square.dashed")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }
        .background(Color.accentColor.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }
}

// MARK: - Collapsed floating pill

struct ResumeFloatingPillView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.isScoringResume {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text("Scoring resume…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if let sc = vm.resumeScore {
                ResumeScoreRow(score: sc) { vm.resumeScore = nil }
            }

            if (vm.resumeScore != nil || vm.isScoringResume)
                && (vm.resumeFileURL != nil || vm.isGeneratingResume) {
                Divider()
            }

            if vm.isGeneratingResume {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text(vm.resumeGenerationStatus.isEmpty ? "Generating resume…" : vm.resumeGenerationStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .animation(.easeInOut(duration: 0.2), value: vm.resumeGenerationStatus)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if let url = vm.resumeFileURL {
                ResumeFileRow(url: url)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Design.Surface.shellFill)
                .opacity(vm.backgroundOpacity)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
    }
}

private struct ResumeFileRow: View {
    @Environment(OverlayViewModel.self) private var vm
    let url: URL

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                FileDragView(fileURL: url)
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text("Drag to upload")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(.leading, 12)
            .padding(.vertical, 8)

            Spacer()
            Divider().frame(height: 24)

            Button { ResumePreviewHelper.shared.show(url: url) } label: {
                Image(systemName: "eye")
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.7))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("Preview")

            Button { vm.resumeFileURL = nil; vm.resumeOutput = "" } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 34)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.trailing, 4)
    }
}

// MARK: - Generation history row

private struct GenerationRow: View {
    let generation: ResumeGeneration
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(generation.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(generation.createdAt, style: .relative)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    scoreBadge(label: "Before", value: generation.beforeScore?.score)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                    scoreBadge(label: "After",  value: generation.afterScore?.score)
                    if let delta = generation.scoreDelta {
                        Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(delta > 0 ? .green : (delta < 0 ? .red : .secondary))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((delta > 0 ? Color.green : (delta < 0 ? Color.red : Color.secondary)).opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(Design.Motion.fast, value: hovering)
    }

    private func scoreBadge(label: String, value: Int?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(color(for: value))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func color(for value: Int?) -> Color {
        guard let v = value else { return .secondary }
        if v >= 80 { return .green }
        if v >= 60 { return .orange }
        return .red
    }
}

// MARK: - Generation detail (diff + scores)

private struct GenerationDetailView: View {
    let generation: ResumeGeneration
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var compareTab: CompareTab = .diff
    @State private var diffLayout: DiffLayout = .inline
    enum CompareTab: Hashable { case diff, before, after }
    enum DiffLayout: Hashable { case inline, sideBySide }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            scoreStrip
            Divider().opacity(0.4)
            compareSelector
            Divider().opacity(0.4)
            body(for: compareTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("All generations").font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            Spacer()

            if let url = generation.fileURL {
                Button {
                    ResumePreviewHelper.shared.show(url: url)
                } label: {
                    Label("Preview", systemImage: "eye").font(.caption)
                }
                .buttonStyle(.borderless)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show DOCX", systemImage: "folder").font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scoreStrip: some View {
        HStack(spacing: 12) {
            scoreColumn(title: "BEFORE", score: generation.beforeScore)
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
            scoreColumn(title: "AFTER", score: generation.afterScore)
            Spacer()
            deltaChip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var deltaChip: some View {
        if let d = generation.scoreDelta {
            VStack(alignment: .trailing, spacing: 1) {
                Text("CHANGE").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
                Text(d >= 0 ? "+\(d)" : "\(d)")
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(d > 0 ? .green : (d < 0 ? .red : .secondary))
            }
        }
    }

    private func scoreColumn(title: String, score: ResumeScore?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Circular gauge
            ZStack {
                Circle()
                    .stroke(color(for: score?.score).opacity(0.18), lineWidth: 3.5)
                    .frame(width: 40, height: 40)
                if let s = score {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(s.score, 0), 100)) / 100.0)
                        .stroke(color(for: s.score),
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(-90))
                }
                Text(score.map { "\($0.score)" } ?? "—")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(color(for: score?.score))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                if let verdict = score?.verdict, !verdict.isEmpty {
                    Text(verdict)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 160, alignment: .leading)
                } else {
                    Text("Not scored")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func color(for value: Int?) -> Color {
        guard let v = value else { return .secondary }
        if v >= 80 { return .green }
        if v >= 60 { return .orange }
        return .red
    }

    private var compareSelector: some View {
        HStack(spacing: 4) {
            tabChip("Diff",   isActive: compareTab == .diff)   { compareTab = .diff }
            tabChip("Before", isActive: compareTab == .before) { compareTab = .before }
            tabChip("After",  isActive: compareTab == .after)  { compareTab = .after }
            Spacer()
            if compareTab == .diff {
                HStack(spacing: 0) {
                    layoutChip("Inline",      isActive: diffLayout == .inline)      { diffLayout = .inline }
                    layoutChip("Side-by-side", isActive: diffLayout == .sideBySide) { diffLayout = .sideBySide }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func layoutChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(Design.Motion.fast) { action() } }) {
            Text(label)
                .font(.system(size: 9, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .white : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.08))
        }
        .buttonStyle(.plain)
    }

    private func tabChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(Design.Motion.fast) { action() } }) {
            Text(label)
                .font(.system(size: 10, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .white : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func body(for tab: CompareTab) -> some View {
        switch tab {
        case .diff:
            if diffLayout == .sideBySide {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        monoText(generation.baseText)
                            .padding(10)
                    }
                    Divider()
                    ScrollView {
                        monoText(generation.generatedText)
                            .padding(10)
                    }
                }
            } else {
                ScrollView {
                    DiffView(before: generation.baseText, after: generation.generatedText)
                        .padding(12)
                }
            }
        case .before:
            ScrollView { monoText(generation.baseText).padding(12) }
        case .after:
            ScrollView { monoText(generation.generatedText).padding(12) }
        }
    }

    private func monoText(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Naive line-level diff view

private struct DiffView: View {
    let before: String
    let after: String

    fileprivate struct Row: Identifiable { let id = UUID(); let kind: Kind; let text: String }
    fileprivate enum Kind { case unchanged, added, removed }

    private var rows: [Row] {
        Self.buildDiff(before: before, after: after)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(row.kind))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(tint(row.kind))
                        .frame(width: 10)
                    Text(row.text.isEmpty ? " " : row.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(row.kind == .removed ? .secondary : .primary)
                        .strikethrough(row.kind == .removed, color: .red.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(bg(row.kind))
            }
        }
    }

    private func marker(_ k: Kind) -> String {
        switch k { case .unchanged: return "·"; case .added: return "+"; case .removed: return "−" }
    }
    private func tint(_ k: Kind) -> Color {
        switch k { case .unchanged: return .secondary.opacity(0.4); case .added: return .green; case .removed: return .red }
    }
    private func bg(_ k: Kind) -> Color {
        switch k { case .unchanged: return .clear; case .added: return .green.opacity(0.08); case .removed: return .red.opacity(0.06) }
    }

    /// Naive LCS-free diff that falls back to "for each `after` line, mark it
    /// added if it's not in `before`; emit removed lines once at the top" —
    /// not as precise as git's diff but readable for resume-length text and
    /// avoids a heavy dep. Good enough for the UX.
    fileprivate static func buildDiff(before: String, after: String) -> [Row] {
        let beforeLines = before.components(separatedBy: "\n")
        let afterLines  = after .components(separatedBy: "\n")
        let beforeSet   = Set(beforeLines.map { $0.trimmingCharacters(in: .whitespaces) }
                                         .filter { !$0.isEmpty })
        let afterSet    = Set(afterLines .map { $0.trimmingCharacters(in: .whitespaces) }
                                         .filter { !$0.isEmpty })

        var rows: [Row] = []
        // Removed lines (present in before but not after)
        for line in beforeLines where !line.trimmingCharacters(in: .whitespaces).isEmpty
            && !afterSet.contains(line.trimmingCharacters(in: .whitespaces)) {
            rows.append(Row(kind: .removed, text: line))
        }
        if !rows.isEmpty {
            rows.append(Row(kind: .unchanged, text: ""))
        }
        // After lines as added/unchanged
        for line in afterLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                rows.append(Row(kind: .unchanged, text: line))
            } else if beforeSet.contains(trimmed) {
                rows.append(Row(kind: .unchanged, text: line))
            } else {
                rows.append(Row(kind: .added, text: line))
            }
        }
        return rows
    }
}
