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
    /// Hides the extracted résumé text body by default so the panel
    /// reads as a tight summary card; the user opts in to view / edit
    /// the raw text via a "Show extracted text" toggle.
    @State private var showsResumeText = false
    /// Same idea for the freshly-generated résumé output — the text
    /// dump stays collapsed unless the user explicitly asks to see it.
    @State private var showsGeneratedText = false

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
        VStack(alignment: .leading, spacing: 18) {
            if let err = importError { importErrorBanner(err) }
            resumeCard
            jdCard
            generateRow
            scoreSection
            outputSection
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - Card-style sections (Build tab)

    /// Résumé card — picker chip, preview/upload/manage actions, and either
    /// the editable text body for the active preset or the inline library
    /// list. Matches the Interview surface's "section card" pattern so the
    /// two flows visually rhyme.
    @ViewBuilder
    private var resumeCard: some View {
        sectionCard(title: "Résumé", systemImage: "doc.richtext") {
            VStack(alignment: .leading, spacing: 10) {
                resumeCardToolbar
                if showResumeLibrary {
                    resumeLibraryCardBody
                } else {
                    resumeBaseCardBody
                }
            }
        }
    }

    /// Top row of the résumé card — the picker chip + the action buttons.
    private var resumeCardToolbar: some View {
        let store = vm.resumeStore
        return HStack(spacing: 6) {
            Menu {
                if store.presets.isEmpty {
                    Text("No saved resumes yet").font(.caption)
                } else {
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
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(store.activePreset?.name ?? "Select résumé")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(store.presets.isEmpty)

            cardChipButton(systemImage: "eye", label: "Preview",
                           disabled: !canPreviewActiveResume,
                           action: previewActiveResume)
                .help("Preview the active résumé (original file)")
            cardChipButton(systemImage: "arrow.up.doc", label: "Upload",
                           action: openUploadPanel)
                .help("Upload PDF / DOCX / RTF / TXT")
            cardChipButton(
                systemImage: showResumeLibrary ? "list.bullet.circle.fill" : "list.bullet.circle",
                label: showResumeLibrary ? "Hide list" : "Manage",
                highlighted: showResumeLibrary,
                action: { showResumeLibrary.toggle() }
            )
            .help("Manage saved résumés")

            Spacer()
        }
    }

    /// Standard chip button used in the card toolbars — keeps every action
    /// chip visually identical regardless of which icon/label it carries.
    private func cardChipButton(systemImage: String,
                                label: String,
                                disabled: Bool = false,
                                highlighted: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(disabled ? .secondary.opacity(0.5)
                             : (highlighted ? .white : .primary))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(
                highlighted ? Design.Accent.blue : Color.white.opacity(0.04)
            ))
            .overlay(Capsule().strokeBorder(
                highlighted ? Design.Accent.blue.opacity(0.40) : Color.white.opacity(0.10),
                lineWidth: 0.5
            ))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// The active résumé's editable text body. Hidden by default once
    /// the preset has content — long résumés flood the panel with
    /// monospaced text the user already imported on purpose. The
    /// `showsResumeText` toggle reveals the full editor on demand.
    /// Empty presets always show the editor so the user has somewhere
    /// to paste.
    @ViewBuilder
    private var resumeBaseCardBody: some View {
        let store = vm.resumeStore
        if let preset = store.activePreset {
            if preset.content.isEmpty || showsResumeText {
                VStack(alignment: .leading, spacing: 6) {
                    if !preset.content.isEmpty {
                        showTextToggle(open: true,
                                       count: preset.content.count,
                                       label: "extracted text")
                    }
                    cardTextEditor(
                        placeholder: "Paste your résumé here — it will be saved to \"\(preset.name)\"",
                        text: Binding(
                            get: { store.activePreset?.content ?? "" },
                            set: { newValue in
                                var updated = preset
                                updated.content = newValue
                                store.update(updated)
                            }
                        ),
                        minHeight: preset.content.isEmpty ? 80 : 60,
                        maxHeight: 160
                    )
                }
            } else {
                resumeCollapsedSummary(preset: preset)
            }
        } else {
            Button {
                let fresh = store.add(name: "My Résumé", content: "")
                store.activePresetID = fresh.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text("Create your first résumé")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Design.Accent.blue))
            }
            .buttonStyle(.plain)
        }
    }

    /// Compact summary card shown in place of the raw resume text. Gives
    /// the user enough signal that the resume is loaded (filename, size)
    /// without flooding the panel; one tap on "Show extracted text"
    /// reveals the full editor.
    private func resumeCollapsedSummary(preset: ResumePreset) -> some View {
        let chars = preset.content.count
        let words = preset.content
            .split(whereSeparator: { $0.isWhitespace })
            .count
        return HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.originalFilename ?? preset.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(words) words · \(chars) chars — text hidden by default")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            showTextToggle(open: false,
                           count: preset.content.count,
                           label: "extracted text")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    /// "Show extracted text" / "Hide extracted text" pill button.
    private func showTextToggle(open: Bool, count: Int, label: String) -> some View {
        Button {
            showsResumeText.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(open ? "Hide \(label)" : "Show \(label)")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Inline résumé library — rendered inside the card when the user
    /// taps "Manage" so they don't have to leave the Build tab.
    @ViewBuilder
    private var resumeLibraryCardBody: some View {
        let store = vm.resumeStore
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Saved résumés")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    let fresh = store.add(name: "Untitled Résumé", content: "")
                    editingResumeID = fresh.id
                    draftResumeName = fresh.name
                    store.activePresetID = fresh.id
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                        Text("Add").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            VStack(spacing: 3) {
                if store.presets.isEmpty {
                    Text("No saved résumés yet — drop a file on this panel or hit Upload.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(store.presets) { p in
                        resumeLibraryRow(p)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    /// Job-description card — single multi-line text area + the
    /// Ctrl+Opt+R hint.
    @ViewBuilder
    private var jdCard: some View {
        @Bindable var vm = vm
        sectionCard(title: "Job Description", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 6) {
                cardTextEditor(
                    placeholder: "Paste the job description here, or copy it and press Ctrl+Opt+R from anywhere.",
                    text: $vm.resumeJD,
                    minHeight: 100,
                    maxHeight: 180
                )
                Text("Tip: Ctrl+Opt+R pastes the clipboard JD and generates in one shot.")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    /// Big primary button at the bottom of the card stack — drives
    /// `vm.generateResume()` and shows the progress state inline. Free
    /// users see how much of the weekly quota is left BEFORE hitting the
    /// cap — previously the limit only surfaced as a block after the fact.
    private var generateRow: some View {
        let disabled = vm.resumeJD.isEmpty || vm.currentResumeText.isEmpty
            || vm.isGeneratingResume || vm.apiKey.isEmpty
        return HStack(spacing: 10) {
            if !vm.entitlement.isPremium {
                let remaining = vm.quota.remainingThisWeek()
                Text(remaining > 0
                     ? "\(remaining) free résumé\(remaining == 1 ? "" : "s") left this week"
                     : "Weekly free limit reached")
                    .font(.caption2)
                    .foregroundColor(remaining > 0 ? .secondary : .orange)
            }
            Spacer()
            Button { vm.generateResume() } label: {
                HStack(spacing: 6) {
                    if vm.isGeneratingResume {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(vm.isGeneratingResume ? "Generating…" : "Generate résumé")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(disabled ? Color.secondary : Design.Accent.blue))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }

    // MARK: - Reusable card scaffolding (mirrors InterviewSetupForm)

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
            content()
        }
    }

    private func cardTextEditor(placeholder: String,
                                text: Binding<String>,
                                minHeight: CGFloat,
                                maxHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .font(.system(size: 12))
                .padding(8)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Preview the active résumé

    /// Can we Quick Look the active résumé? True if there's an active preset
    /// with either the original DOCX bytes attached or non-empty text we can
    /// dump to a .txt fallback.
    private var canPreviewActiveResume: Bool {
        guard let p = vm.resumeStore.activePreset else { return false }
        if p.originalDOCX != nil { return true }
        return !p.content.isEmpty
    }

    /// Spin up a Quick Look preview for the active résumé. Prefers the
    /// original DOCX bytes (so formatting renders correctly); falls back
    /// to a plain-text dump for résumés imported from PDF/RTF/TXT where
    /// we didn't retain the source.
    private func previewActiveResume() {
        guard let p = vm.resumeStore.activePreset else { return }
        if let docx = p.originalDOCX {
            let filename = p.originalFilename ?? "\(p.name).docx"
            ResumePreviewHelper.shared.showDOCX(docx, suggestedFilename: filename)
        } else if !p.content.isEmpty {
            ResumePreviewHelper.shared.showPlainText(p.content, suggestedName: p.name)
        }
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
        VStack(alignment: .leading, spacing: 18) {
            sectionCard(title: "Past generations", systemImage: "clock.arrow.circlepath") {
                if vm.resumeStore.generations.isEmpty {
                    generationsEmptyCardBody
                } else {
                    generationsListCardBody
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var generationsEmptyCardBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No generations yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Text("Generate a tailored résumé from the Build tab — every run lands here with a before/after score.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder
    private var generationsListCardBody: some View {
        VStack(spacing: 6) {
            ForEach(vm.resumeStore.generations) { g in
                GenerationRow(
                    generation: g,
                    onOpen: { viewingGenerationID = g.id },
                    onDelete: { vm.resumeStore.deleteGeneration(id: g.id) }
                )
            }
        }
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
                    // Generated résumé body stays collapsed by default —
                    // most users just preview / drag the DOCX without
                    // ever needing to read the raw text. Toggle reveals
                    // the monospaced dump for verification.
                    HStack {
                        Button {
                            showsGeneratedText.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showsGeneratedText ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(showsGeneratedText ? "Hide generated text" : "Show generated text")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.04)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    if showsGeneratedText {
                        ScrollView {
                            Text(vm.resumeOutput)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(minHeight: 100, maxHeight: 200)
                    }

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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(generation.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(generation.createdAt, style: .relative)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    scoreBadge(label: "Before", value: generation.beforeScore?.score)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                    scoreBadge(label: "After", value: generation.afterScore?.score)
                    if let delta = generation.scoreDelta {
                        Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(delta > 0 ? .green : (delta < 0 ? .red : .secondary))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((delta > 0 ? Color.green : (delta < 0 ? Color.red : Color.secondary)).opacity(0.14))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
            }
            VStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(hovering ? 0.9 : 0.5))
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(hovering ? 0.18 : 0.10), lineWidth: 0.5)
        )
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
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            scoreCard
            compareCard
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("All generations")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Spacer()

            if let url = generation.fileURL {
                detailChip(icon: "eye", label: "Preview") {
                    ResumePreviewHelper.shared.show(url: url)
                }
                detailChip(icon: "folder", label: "Show DOCX") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.04)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Delete this generation")
        }
    }

    private func detailChip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Score summary card — before/after gauges + delta. Mirrors the
    /// section-card pattern from Interview / Build so the detail view
    /// reads as a stack of cards rather than a flat strip.
    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Scores")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            HStack(spacing: 14) {
                scoreColumn(title: "BEFORE", score: generation.beforeScore)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                scoreColumn(title: "AFTER", score: generation.afterScore)
                Spacer()
                deltaChip
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
    }

    /// Comparison card — wraps the tab selector + the chosen body
    /// (diff / before / after) in a single bordered surface.
    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Compare")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            VStack(spacing: 0) {
                compareSelector
                Divider().opacity(0.4)
                body(for: compareTab)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
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
