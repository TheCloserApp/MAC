import Foundation
import Observation

/// User-customisable visibility + sizing for the lower input bar. Lives
/// in `OverlayViewModel` and is persisted to `UserDefaults` so toggles
/// survive across launches.
///
/// Each toggle controls a single button in the bar; the user can hide
/// any of them via Preferences → Panel. The brand logo and the text
/// input are always present (they're the bar's identity), so they don't
/// have toggles.
@Observable
@MainActor
final class BarCustomization {
    static let shared = BarCustomization()

    // MARK: - Element visibility

    var showNewSession: Bool { didSet { save("bar.showNewSession", showNewSession) } }
    var showHistory:    Bool { didSet { save("bar.showHistory",    showHistory)    } }
    var showMode:       Bool { didSet { save("bar.showMode",       showMode)       } }
    var showResume:     Bool { didSet { save("bar.showResume",     showResume)     } }
    var showModel:      Bool { didSet { save("bar.showModel",      showModel)      } }
    var showMic:        Bool { didSet { save("bar.showMic",        showMic)        } }
    var showSend:       Bool { didSet { save("bar.showSend",       showSend)       } }
    /// Whether the multi-line "Ask anything" text field appears in the
    /// bar. Users who drive the overlay almost entirely by voice or
    /// shortcuts can hide it to reclaim horizontal space — the brand
    /// pill, mic, and send still work without it.
    var showTextField:  Bool { didSet { save("bar.showTextField",  showTextField)  } }

    // MARK: - Typography

    /// Base font size (in points) for the bar's controls and text. The
    /// rest of the bar's typography scales relative to this — chips and
    /// the text field both read it. Range: 10–15. Default: 13.
    var fontSize: Double { didSet { save("bar.fontSize", fontSize) } }

    /// Convenience: derived font for the bar's chip labels (mode picker
    /// label, model picker label).
    var chipFontSize: CGFloat { CGFloat(fontSize - 2) }

    private init() {
        let d = UserDefaults.standard

        // Defaults: every toggle on, fontSize 13. `object(forKey:) ?? true`
        // pattern so a missing key reads as "on" instead of "false".
        showNewSession = (d.object(forKey: "bar.showNewSession") as? Bool) ?? true
        showHistory    = (d.object(forKey: "bar.showHistory")    as? Bool) ?? true
        showMode       = (d.object(forKey: "bar.showMode")       as? Bool) ?? true
        showResume     = (d.object(forKey: "bar.showResume")     as? Bool) ?? true
        showModel      = (d.object(forKey: "bar.showModel")      as? Bool) ?? true
        showMic        = (d.object(forKey: "bar.showMic")        as? Bool) ?? true
        showSend       = (d.object(forKey: "bar.showSend")       as? Bool) ?? true
        showTextField  = (d.object(forKey: "bar.showTextField")  as? Bool) ?? true
        fontSize       = (d.object(forKey: "bar.fontSize")       as? Double) ?? 13.0
    }

    private func save<T>(_ key: String, _ value: T) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Restore the everything-on, default-size state. Used by the "Reset
    /// to defaults" button in the Panel preferences tab.
    func resetToDefaults() {
        showNewSession = true
        showHistory    = true
        showMode       = true
        showResume     = true
        showModel      = true
        showMic        = true
        showSend       = true
        showTextField  = true
        fontSize       = 13.0
    }
}
