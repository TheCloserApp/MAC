//! Make the overlay window invisible to screen capture and keep it pinned.
//!
//! The defining trick of the app: `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`
//! tells the Desktop Window Manager to omit this window from any screen capture
//! — Zoom / Meet / Teams / OBS / Game Bar all record the screen *without* it,
//! while it stays fully visible to the user. This is the Windows equivalent of
//! the macOS `NSWindow.sharingType = .none`.
//!
//! winit (via eframe) already gives us a borderless, transparent, always-on-top,
//! no-taskbar window through `ViewportBuilder`; the only thing it can't express
//! is the capture-exclusion affinity, so we reach for the Win32 API directly.
//! We find our own window by its unique title rather than threading an `HWND`
//! out of eframe, which keeps this independent of eframe's internals.

/// The unique window title used both for `ViewportBuilder::with_title` and to
/// locate the `HWND` here. The title bar is hidden, so the user never sees it.
pub const WINDOW_TITLE: &str = "thecloser \u{2009}overlay";

/// Apply capture-exclusion (and belt-and-braces tool-window flags) to our
/// window. Returns `true` once it has been applied so the caller can stop
/// retrying. Safe to call every frame until it succeeds — the window may not
/// exist yet on the very first frame.
#[cfg(windows)]
pub fn apply_overlay_flags() -> bool {
    use windows::core::PCWSTR;
    use windows::Win32::UI::WindowsAndMessaging::{
        FindWindowW, GetWindowLongPtrW, SetWindowDisplayAffinity, SetWindowLongPtrW, SetWindowPos,
        GWL_EXSTYLE, HWND_TOPMOST, SWP_FRAMECHANGED, SWP_NOMOVE, SWP_NOSIZE, WDA_EXCLUDEFROMCAPTURE,
        WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
    };

    let title: Vec<u16> = WINDOW_TITLE.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let hwnd = match FindWindowW(PCWSTR::null(), PCWSTR(title.as_ptr())) {
            Ok(h) if !h.0.is_null() => h,
            _ => return false, // window not created yet — try again next frame
        };

        // The core trick. Ignore the result: on Windows < 10 2004 this affinity
        // value is unsupported and the call fails, but the app is still usable.
        let _ = SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);

        // Tool window: keep it out of Alt-Tab and the taskbar even if the winit
        // hint didn't take. Re-assert top-most for good measure.
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let want = (ex | WS_EX_TOOLWINDOW.0 as isize) & !(WS_EX_APPWINDOW.0 as isize);
        if want != ex {
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
            let _ = SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED,
            );
        }
    }
    true
}

/// Non-Windows stub so the crate builds on any host (the overlay's privacy
/// guarantee only exists on Windows). Reports "applied" so the caller stops
/// polling.
#[cfg(not(windows))]
pub fn apply_overlay_flags() -> bool {
    true
}
