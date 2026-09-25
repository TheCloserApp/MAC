// On Windows release builds, run without a console window (it's an overlay).
#![cfg_attr(all(target_os = "windows", not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod audio;
mod backend;
mod hotkeys;
mod overlay;
mod theme;
mod transcribe;

use copilot_core::settings::Settings;

fn main() -> eframe::Result {
    // UI-gallery mode: redirect the whole config directory before anything
    // reads it, so a demo run can't touch the user's real settings, prompt
    // library, or résumés.
    if let Some(dir) = std::env::var_os("THECLOSER_DEMO") {
        copilot_core::store::set_config_dir(std::path::PathBuf::from(dir));
    }
    let settings_path = Settings::default_path();
    let settings = Settings::load(&settings_path);

    let viewport = egui::ViewportBuilder::default()
        .with_title(overlay::WINDOW_TITLE)
        .with_app_id("tech.thecloser.windows")
        .with_inner_size([settings.panel_width, settings.panel_height])
        // Must not exceed the collapsed brand pill (`app::PILL_SIZE`), or the
        // pill gets clamped back up. Keyboard/grip resizes clamp to their own,
        // larger minimum in `app.rs`.
        .with_min_inner_size([56.0, 40.0])
        .with_position([settings.panel_x, settings.panel_y])
        .with_decorations(false)
        .with_transparent(true)
        .with_resizable(true)
        .with_always_on_top()
        .with_taskbar(false);

    let options = eframe::NativeOptions {
        viewport,
        // Don't grab focus when shown — it's an overlay you read past.
        ..Default::default()
    };

    eframe::run_native(
        "thecloser",
        options,
        Box::new(move |cc| Ok(Box::new(app::App::new(cc, settings, settings_path)))),
    )
}
