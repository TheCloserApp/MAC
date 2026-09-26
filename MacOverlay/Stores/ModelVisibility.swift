import Foundation
import Observation

/// Per-user list of which models from `OverlayViewModel.availableModels`
/// the model picker actually shows. The full catalogue is large enough
/// that surfacing every model on every chip menu would feel noisy — this
/// store lets the user curate the picker via Settings → AI.
///
/// Persisted as a set of *hidden* ids (rather than a set of visible ones)
/// so when we ship a new model, existing users see it by default without
/// us needing a migration step.
@Observable
@MainActor
final class ModelVisibility {
    static let shared = ModelVisibility()

    private static let storageKey = "modelVisibility.hidden"

    private(set) var hidden: Set<String> {
        didSet { persist() }
    }

    /// The models a TheCloser Pro plan includes (set by `ProAccount`), or
    /// nil for no limit. Models outside it disappear from every picker and
    /// from Settings, rather than being offered and then refused.
    var allowed: Set<String>?

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        self.hidden = Set(raw)
    }

    /// True when the current plan includes this model id.
    func isAllowed(_ id: String) -> Bool { allowed?.contains(id) ?? true }

    /// True when the picker should show this model id.
    func isVisible(_ id: String) -> Bool { isAllowed(id) && !hidden.contains(id) }

    /// True when this id is currently the *only* visible model in `allModelIDs`.
    /// The UI uses this to disable the toggle (with a tooltip) instead of
    /// letting the user click into the silent no-op in `toggle(_:allModelIDs:)`.
    func isOnlyVisible(_ id: String, allModelIDs: [String]) -> Bool {
        guard !hidden.contains(id) else { return false }
        return allModelIDs.allSatisfy { $0 == id || hidden.contains($0) }
    }

    /// Toggle visibility for a model id. If toggling would hide the very
    /// last model, no-op — the picker has to render at least one option.
    /// Callers should use `isOnlyVisible` to disable the control rather
    /// than relying on this silent no-op.
    func toggle(_ id: String, allModelIDs: [String]) {
        if hidden.contains(id) {
            hidden.remove(id)
        } else {
            let stillVisible = allModelIDs.filter { !hidden.contains($0) && $0 != id }
            guard !stillVisible.isEmpty else { return }
            hidden.insert(id)
        }
    }

    /// Reset to "every model visible" — used by the "Show all" button in
    /// Settings.
    func showAll() { hidden.removeAll() }

    private func persist() {
        UserDefaults.standard.set(Array(hidden), forKey: Self.storageKey)
    }
}
