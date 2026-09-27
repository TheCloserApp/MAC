import Speech
import SwiftUI

/// The language spoken in the interview, as a chip on the setup screen.
/// Takes effect from the next recording.
struct TranscriptionLanguagePicker: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        Menu {
            ForEach(languages) { language in
                Button {
                    vm.transcriptionLanguageID = language.id
                } label: {
                    if language.id == vm.transcriptionLanguageID {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                Text(TranscriptionLanguage.language(for: vm.transcriptionLanguageID)?.name ?? "English (US)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Design.Ink.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(Design.Surface.controlFill))
            .overlay(Capsule().strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The language spoken in the interview")
    }

    /// Languages this Mac's speech recognizer supports, plus the current
    /// choice so the chip never shows something that isn't listed.
    private var languages: [TranscriptionLanguage] {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
        })
        guard !supported.isEmpty else { return TranscriptionLanguage.all }
        return TranscriptionLanguage.all.filter {
            supported.contains($0.id) || $0.id == vm.transcriptionLanguageID
        }
    }
}
