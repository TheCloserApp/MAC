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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
            let text = try ResumeImporter.importFile(url: url)
            let name = ResumeImporter.suggestedName(for: url)
            let preset = vm.resumeStore.add(name: name.isEmpty ? "Imported Resume" : name, content: text)
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
        HStack {
            Text("Tailor a resume to any job description")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
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
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Generating…").font(.system(size: 12)).foregroundColor(.secondary)
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
                    Text("Generating resume…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if let url = vm.resumeFileURL {
                ResumeFileRow(url: url)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(vm.backgroundOpacity)
        }
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
