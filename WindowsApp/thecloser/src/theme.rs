//! Design tokens + reusable widgets, ported from the macOS app's `Design.swift`.
//!
//! Same ChatGPT-desktop dark palette (#212121 shell, charcoal controls,
//! #ececec/#c5c5c5/#8e8e8e ink), the per-mode accent colors, the 5-bar
//! animated waveform brand, glass cards, and chip/icon buttons — so the
//! Windows overlay reads as the same product. Every interactive widget here
//! animates its hover state (the Mac app's `HoverLift` / `hoverHighlight`)
//! so the whole shell feels alive rather than snapping between states.

use egui::{
    pos2, vec2, Align2, Color32, FontId, Pos2, Rect, Response, RichText, Rounding, Sense, Stroke,
    Ui, Vec2,
};

use copilot_core::SessionMode;

// ── Surfaces (the dark "glass" base) ─────────────────────────────────────────
pub const SHELL: Color32 = Color32::from_rgb(0x21, 0x21, 0x21);
pub const RAISED: Color32 = Color32::from_rgb(0x2f, 0x2f, 0x2f);
pub const CONTROL: Color32 = Color32::from_rgb(0x2a, 0x2a, 0x2a);
pub const CONTROL_HOVER: Color32 = Color32::from_rgb(0x33, 0x33, 0x33);
pub const INPUT: Color32 = Color32::from_rgb(0x30, 0x30, 0x30);
pub const BUBBLE: Color32 = Color32::from_rgb(0x30, 0x30, 0x30);
pub const PREVIEW: Color32 = Color32::from_rgb(0x27, 0x27, 0x27);
pub const CODE: Color32 = Color32::from_rgb(0x17, 0x17, 0x17);
// NB: premultiplied white = alpha in ALL channels. `(255,255,255,a)` is
// additive in egui and renders as a glow instead of a tint.
pub const SEPARATOR: Color32 = Color32::from_rgba_premultiplied(20, 20, 20, 20);
pub const HAIRLINE: Color32 = Color32::from_rgba_premultiplied(26, 26, 26, 26);
pub const STRONG_HAIRLINE: Color32 = Color32::from_rgba_premultiplied(36, 36, 36, 36);

// ── Ink (text) ───────────────────────────────────────────────────────────────
pub const INK: Color32 = Color32::from_rgb(0xec, 0xec, 0xec);
pub const INK2: Color32 = Color32::from_rgb(0xc5, 0xc5, 0xc5);
pub const INK3: Color32 = Color32::from_rgb(0x8e, 0x8e, 0x8e);
pub const INK_MUTED: Color32 = Color32::from_rgb(0x6f, 0x6f, 0x6f);
pub const INK_INVERSE: Color32 = Color32::from_rgb(0x21, 0x21, 0x21);

// ── Accents ──────────────────────────────────────────────────────────────────
pub const CHATGPT: Color32 = Color32::from_rgb(16, 163, 127);
pub const BLUE: Color32 = Color32::from_rgb(10, 132, 255);
pub const GREEN: Color32 = Color32::from_rgb(52, 199, 89);
pub const RED: Color32 = Color32::from_rgb(255, 69, 58);
pub const AMBER: Color32 = Color32::from_rgb(255, 159, 10);
pub const PURPLE: Color32 = Color32::from_rgb(191, 90, 242);
pub const ORANGE: Color32 = Color32::from_rgb(255, 149, 10);

/// Hover-animation time, matching the Mac `Design.Motion.fast` (0.16s).
pub const HOVER_T: f32 = 0.14;

/// Per-mode accent (general purple, interview green, meeting blue, call orange).
pub fn mode_color(mode: SessionMode) -> Color32 {
    match mode {
        SessionMode::General => PURPLE,
        SessionMode::Interview => GREEN,
        SessionMode::Meeting => BLUE,
        SessionMode::Call => ORANGE,
    }
}

/// Install the global egui style so every default widget already matches the
/// palette (chip-like buttons, dark text fields, accent selection).
pub fn install(ctx: &egui::Context, font_scale: f32) {
    use egui::style::{Selection, WidgetVisuals, Widgets};

    install_fonts(ctx);

    let mut v = egui::Visuals::dark();
    v.override_text_color = Some(INK);
    v.panel_fill = Color32::TRANSPARENT;
    v.window_fill = SHELL;
    v.window_stroke = Stroke::new(0.75, HAIRLINE);
    v.window_rounding = Rounding::same(12.0);
    v.extreme_bg_color = INPUT; // TextEdit background
    v.faint_bg_color = CONTROL;
    v.selection = Selection { bg_fill: CHATGPT.gamma_multiply(0.55), stroke: Stroke::new(1.0, CHATGPT) };
    v.hyperlink_color = BLUE;
    v.popup_shadow = egui::epaint::Shadow {
        offset: vec2(0.0, 4.0),
        blur: 16.0,
        spread: 0.0,
        color: Color32::from_black_alpha(120),
    };

    let widget = |bg: Color32, fg: Color32, stroke: Color32| WidgetVisuals {
        bg_fill: bg,
        weak_bg_fill: bg,
        bg_stroke: Stroke::new(0.5, stroke),
        fg_stroke: Stroke::new(1.0, fg),
        // 5px, not 8: egui reuses this radius for checkboxes, and at their
        // ~14px size anything larger renders as a circle — i.e. it reads as a
        // radio button. Chips and pills paint their own capsule shape.
        rounding: Rounding::same(5.0),
        expansion: 0.0,
    };
    v.widgets = Widgets {
        noninteractive: widget(Color32::TRANSPARENT, INK2, SEPARATOR),
        inactive: widget(CONTROL, INK2, HAIRLINE),
        hovered: widget(CONTROL_HOVER, INK, STRONG_HAIRLINE),
        active: widget(RAISED, INK, STRONG_HAIRLINE),
        open: widget(CONTROL, INK, HAIRLINE),
    };
    ctx.set_visuals(v);

    let mut style = (*ctx.style()).clone();
    style.spacing.item_spacing = vec2(6.0, 6.0);
    style.spacing.button_padding = vec2(9.0, 5.0);
    style.spacing.window_margin = egui::Margin::same(0.0);
    style.spacing.menu_margin = egui::Margin::same(6.0);
    style.spacing.interact_size.y = 24.0;
    style.spacing.scroll = egui::style::ScrollStyle::thin();
    ctx.set_style(style);

    if font_scale > 0.4 {
        ctx.set_zoom_factor(font_scale);
    }
}

/// Put the platform's native UI font in front of egui's bundled fonts so text
/// renders like a native modern app — Segoe UI (Variable) on Windows, SF Pro
/// on macOS (for local previews of this Windows-first app). The bundled fonts
/// stay as fallback for glyphs the system font lacks. No-op if the files
/// aren't there, so this can never break startup.
fn install_fonts(ctx: &egui::Context) {
    let candidates: &[&str] = &[
        "C:\\Windows\\Fonts\\SegUIVar.ttf",  // Segoe UI Variable (Win 11)
        "C:\\Windows\\Fonts\\segoeui.ttf",   // Segoe UI (Win 10)
        "/System/Library/Fonts/SFNS.ttf",    // SF Pro (macOS dev preview)
    ];
    for path in candidates {
        if let Ok(bytes) = std::fs::read(path) {
            let mut fonts = egui::FontDefinitions::default();
            fonts
                .font_data
                .insert("system-ui".to_owned(), egui::FontData::from_owned(bytes));
            fonts
                .families
                .entry(egui::FontFamily::Proportional)
                .or_default()
                .insert(0, "system-ui".to_owned());
            ctx.set_fonts(fonts);
            return;
        }
    }
}

/// A rounded glass surface frame (the `glassCard` treatment). `bg` fades the
/// background only — the user's background-opacity setting — so the content
/// stays readable while the panel thins out over the call window behind it.
pub fn card_alpha(radius: f32, bg: f32) -> egui::Frame {
    egui::Frame::none()
        .fill(SHELL.gamma_multiply(bg.clamp(0.0, 1.0)))
        .rounding(Rounding::same(radius))
        .stroke(Stroke::new(0.75, HAIRLINE))
        .inner_margin(egui::Margin::symmetric(14.0, 12.0))
        .shadow(egui::epaint::Shadow {
            offset: vec2(0.0, 2.0),
            blur: 10.0,
            spread: 0.0,
            color: Color32::from_black_alpha(60),
        })
}

/// Smoothly-animated hover fraction for a widget: 0.0 idle → 1.0 hovered.
fn hover_t(ui: &Ui, resp: &Response) -> f32 {
    ui.ctx()
        .animate_bool_with_time(resp.id.with("hover"), resp.hovered(), HOVER_T)
}

/// Measure a label without committing to a color.
///
/// Text color must be baked in at layout time — `Painter::galley`'s color
/// argument is only a *fallback* for runs that have none, so a galley laid
/// out in one color can never be repainted in another. Widgets whose text
/// color depends on hover/selection therefore measure first with this, then
/// paint with `Painter::text` once the final color is known.
fn text_size(ui: &Ui, text: &str, font: &FontId) -> Vec2 {
    ui.fonts(|f| f.layout_no_wrap(text.to_owned(), font.clone(), INK).size())
}

/// A capsule "chip" button (mode/model pickers, quick actions). `accent`
/// fills it as a selected/primary chip. Hover eases between fills instead of
/// snapping, like the Mac `hoverLift`.
pub fn chip(ui: &mut Ui, text: &str, accent: Option<Color32>) -> Response {
    let font = FontId::proportional(11.0);
    let pad = vec2(11.0, 5.5);
    let size = text_size(ui, text, &font) + pad * 2.0;
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    if !ui.is_rect_visible(rect) {
        return resp;
    }
    let hov = hover_t(ui, &resp);
    let (fill, fg, stroke) = match accent {
        Some(c) => (c.gamma_multiply(1.0 + 0.10 * hov), INK_INVERSE, c.gamma_multiply(1.2)),
        None => (CONTROL.lerp_to_gamma(CONTROL_HOVER, hov), INK2.lerp_to_gamma(INK, hov), HAIRLINE),
    };
    let r = rect.height() / 2.0;
    ui.painter().rect(rect, Rounding::same(r), fill, Stroke::new(0.5, stroke));
    ui.painter()
        .text(rect.center(), Align2::CENTER_CENTER, text, font, fg);
    resp.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// The Mac app's primary capsule: white (ink) fill, dark inverse text —
/// "Start interview", "Continue session", Save. Hover lifts brightness a hair.
pub fn primary_capsule(ui: &mut Ui, text: &str) -> Response {
    let font = FontId::proportional(12.5);
    let pad = vec2(17.0, 8.0);
    let size = text_size(ui, text, &font) + pad * 2.0;
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    if !ui.is_rect_visible(rect) {
        return resp;
    }
    let hov = hover_t(ui, &resp);
    let fill = INK.lerp_to_gamma(Color32::WHITE, hov);
    let r = rect.height() / 2.0;
    ui.painter()
        .rect(rect, Rounding::same(r), fill, Stroke::new(0.5, STRONG_HAIRLINE));
    ui.painter()
        .text(rect.center(), Align2::CENTER_CENTER, text, font, INK_INVERSE);
    resp.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Segmented pill, Mac style: selected → ink fill + inverse text; idle →
/// control fill. Used for mode tabs / audio pickers.
pub fn segment_pill(ui: &mut Ui, text: &str, selected: bool) -> Response {
    let font = FontId::proportional(11.5);
    let pad = vec2(12.0, 6.5);
    let size = text_size(ui, text, &font) + pad * 2.0;
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    if !ui.is_rect_visible(rect) {
        return resp;
    }
    let hov = hover_t(ui, &resp);
    let sel = ui
        .ctx()
        .animate_bool_with_time(resp.id.with("sel"), selected, HOVER_T);
    let fill = CONTROL.lerp_to_gamma(CONTROL_HOVER, hov).lerp_to_gamma(INK, sel);
    let stroke = if selected {
        Stroke::new(0.5, Color32::from_rgba_premultiplied(56, 56, 56, 56))
    } else {
        Stroke::new(0.5, HAIRLINE)
    };
    let r = rect.height() / 2.0;
    ui.painter().rect(rect, Rounding::same(r), fill, stroke);
    // Text flips once the fill is mostly there — a clean crossfade.
    let fg = if sel > 0.5 { INK_INVERSE } else { INK };
    ui.painter()
        .text(rect.center(), Align2::CENTER_CENTER, text, font, fg);
    resp.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Vector icons painted with the epaint primitives — no font/emoji glyph
/// roulette, pixel-identical on Windows and macOS.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Icon {
    /// Send (arrow up).
    ArrowUp,
    Play,
    Pause,
    /// Stop generating (square).
    Stop,
    ChevronDown,
    ChevronUp,
    /// Full-conversation list (three lines).
    List,
    /// Live Focus card (rounded rect outline).
    Card,
    /// Hide / dismiss (minus).
    Minus,
}

/// Paint `icon` centered in `rect`, scaled to it, in `tint`.
pub fn paint_icon(painter: &egui::Painter, rect: Rect, icon: Icon, tint: Color32) {
    let c = rect.center();
    let r = rect.width() / 2.0;
    let w = (r * 0.16).max(1.3); // stroke weight
    let s = Stroke::new(w, tint);
    match icon {
        Icon::ArrowUp => {
            let h = r * 0.62;
            painter.line_segment([pos2(c.x, c.y + h), pos2(c.x, c.y - h)], s);
            painter.line_segment([pos2(c.x - h * 0.62, c.y - h * 0.30), pos2(c.x, c.y - h)], s);
            painter.line_segment([pos2(c.x + h * 0.62, c.y - h * 0.30), pos2(c.x, c.y - h)], s);
        }
        Icon::Play => {
            let h = r * 0.60;
            painter.add(egui::Shape::convex_polygon(
                vec![
                    pos2(c.x - h * 0.62, c.y - h),
                    pos2(c.x + h * 0.86, c.y),
                    pos2(c.x - h * 0.62, c.y + h),
                ],
                tint,
                Stroke::NONE,
            ));
        }
        Icon::Pause => {
            let h = r * 0.58;
            let bw = (r * 0.24).max(1.6);
            let gap = r * 0.30;
            for side in [-1.0_f32, 1.0] {
                let x = c.x + side * gap;
                painter.rect_filled(
                    Rect::from_min_max(pos2(x - bw / 2.0, c.y - h), pos2(x + bw / 2.0, c.y + h)),
                    Rounding::same(bw / 2.0),
                    tint,
                );
            }
        }
        Icon::Stop => {
            let h = r * 0.52;
            painter.rect_filled(Rect::from_center_size(c, Vec2::splat(h * 2.0)), Rounding::same(h * 0.3), tint);
        }
        Icon::ChevronDown | Icon::ChevronUp => {
            let dir = if icon == Icon::ChevronDown { 1.0 } else { -1.0 };
            let wd = r * 0.55;
            let hh = r * 0.30 * dir;
            painter.line_segment([pos2(c.x - wd, c.y - hh), pos2(c.x, c.y + hh)], s);
            painter.line_segment([pos2(c.x + wd, c.y - hh), pos2(c.x, c.y + hh)], s);
        }
        Icon::List => {
            let wd = r * 0.60;
            for i in -1..=1 {
                let y = c.y + i as f32 * r * 0.42;
                painter.line_segment([pos2(c.x - wd, y), pos2(c.x + wd, y)], s);
            }
        }
        Icon::Card => {
            let half = vec2(r * 0.62, r * 0.48);
            painter.rect_stroke(Rect::from_center_size(c, half * 2.0), Rounding::same(2.5), s);
        }
        Icon::Minus => {
            let wd = r * 0.55;
            painter.line_segment([pos2(c.x - wd, c.y), pos2(c.x + wd, c.y)], s);
        }
    }
}

/// A circular icon button (send, pause, strip controls) with a painted vector
/// icon. `active_fill` paints an accent background. Hover eases.
pub fn icon_button(
    ui: &mut Ui,
    icon: Icon,
    tint: Color32,
    active_fill: Option<Color32>,
    size: f32,
) -> Response {
    let (rect, resp) = ui.allocate_exact_size(Vec2::splat(size), Sense::click());
    if !ui.is_rect_visible(rect) {
        return resp;
    }
    let hov = hover_t(ui, &resp);
    let painter = ui.painter();
    let fill = active_fill.unwrap_or_else(|| CONTROL.lerp_to_gamma(CONTROL_HOVER, hov));
    let stroke = if active_fill.is_some() {
        Stroke::new(0.5, tint.gamma_multiply(0.6))
    } else {
        Stroke::new(0.5, HAIRLINE.lerp_to_gamma(STRONG_HAIRLINE, hov))
    };
    painter.circle(rect.center(), size / 2.0, fill, stroke);
    let tint = if active_fill.is_some() { tint } else { tint.lerp_to_gamma(INK, hov * 0.5) };
    paint_icon(painter, Rect::from_center_size(rect.center(), Vec2::splat(size * 0.52)), icon, tint);
    resp.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// A small filled dot (mode indicators) — painted, since `●` is missing from
/// several fallback fonts and renders as tofu.
pub fn dot(ui: &mut Ui, color: Color32, radius: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(radius * 2.0 + 2.0), Sense::hover());
    ui.painter().circle_filled(rect.center(), radius, color);
}

/// Paint a small ⌄ chevron over the right edge of `rect` — used to decorate
/// text-only menu buttons (the label reserves trailing spaces for it).
pub fn overlay_chevron(painter: &egui::Painter, rect: Rect, tint: Color32) {
    let c = pos2(rect.right() - 12.0, rect.center().y + 0.5);
    let wd = 3.4;
    let hh = 2.2;
    let s = Stroke::new(1.4, tint);
    painter.line_segment([pos2(c.x - wd, c.y - hh), pos2(c.x, c.y + hh)], s);
    painter.line_segment([pos2(c.x + wd, c.y - hh), pos2(c.x, c.y + hh)], s);
}

/// Paint a horizontal ⋯ over `rect` — decorates the session-menu button.
pub fn overlay_dots(painter: &egui::Painter, rect: Rect, tint: Color32) {
    for i in -1..=1 {
        painter.circle_filled(pos2(rect.center().x + i as f32 * 5.0, rect.center().y), 1.5, tint);
    }
}

/// The tiny mm:ss / h:mm:ss live-session timer capsule from the Mac transcript
/// strip: a dot (red while recording, grey when paused) + monospace time on a
/// softly tinted capsule. The dot pulses gently while live.
pub fn timer_capsule(ui: &mut Ui, t: f64, secs: u64, live: bool) {
    let text = if secs >= 3600 {
        format!("{}:{:02}:{:02}", secs / 3600, (secs % 3600) / 60, secs % 60)
    } else {
        format!("{:02}:{:02}", secs / 60, secs % 60)
    };
    let font = FontId::monospace(10.0);
    let galley = ui.painter().layout_no_wrap(text, font, INK2);
    let dot_r = 2.6_f32;
    let pad = vec2(7.0, 3.0);
    let size = vec2(galley.size().x + dot_r * 2.0 + 5.0, galley.size().y) + pad * 2.0;
    let (rect, _) = ui.allocate_exact_size(size, Sense::hover());
    if !ui.is_rect_visible(rect) {
        return;
    }
    let accent = if live { RED } else { INK3 };
    let painter = ui.painter();
    painter.rect(rect, Rounding::same(rect.height() / 2.0), accent.gamma_multiply(0.10), Stroke::NONE);
    let a = if live { 0.55 + 0.45 * ((t * 2.2).sin().abs() as f32) } else { 0.9 };
    painter.circle_filled(
        pos2(rect.left() + pad.x + dot_r, rect.center().y),
        dot_r,
        accent.gamma_multiply(a),
    );
    painter.galley(
        pos2(rect.left() + pad.x + dot_r * 2.0 + 5.0, rect.center().y - galley.size().y / 2.0),
        galley,
        INK2,
    );
}

/// Small rotating-arc spinner (the Mac `ProgressView` in the "Thinking…" row).
pub fn spinner(ui: &mut Ui, t: f64, radius: f32, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(radius * 2.0 + 2.0), Sense::hover());
    if !ui.is_rect_visible(rect) {
        return;
    }
    let painter = ui.painter();
    let c = rect.center();
    let start = t * 3.6;
    let n = 20;
    let points: Vec<Pos2> = (0..=n)
        .map(|i| {
            let a = start + (i as f64 / n as f64) * std::f64::consts::PI * 1.4;
            pos2(c.x + radius * a.cos() as f32, c.y + radius * a.sin() as f32)
        })
        .collect();
    painter.add(egui::Shape::line(points, Stroke::new(1.6, color)));
}

/// Amber "no API key" banner (the Mac `MissingKeyWarning`). Clickable — the
/// caller routes it to the Profile surface. Returns the click response.
pub fn warning_banner(ui: &mut Ui, text: &str) -> Response {
    let desired_w = ui.available_width();
    let resp = ui
        .scope(|ui| {
            egui::Frame::none()
                .fill(AMBER.gamma_multiply(0.12))
                .rounding(Rounding::same(9.0))
                .stroke(Stroke::new(0.5, AMBER.gamma_multiply(0.35)))
                .inner_margin(egui::Margin::symmetric(11.0, 8.0))
                .show(ui, |ui| {
                    ui.set_width(desired_w - 22.0);
                    ui.horizontal(|ui| {
                        warning_triangle(ui, 13.0);
                        ui.add(
                            egui::Label::new(RichText::new(text).size(11.0).color(INK))
                                .wrap(),
                        );
                    });
                });
        })
        .response;
    let resp = resp.interact(Sense::click());
    resp.on_hover_cursor(egui::CursorIcon::PointingHand)
}

/// Painted ⚠ (rounded triangle + exclamation) — the glyph is tofu in some
/// fallback fonts.
fn warning_triangle(ui: &mut Ui, size: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(size), Sense::hover());
    let p = ui.painter();
    let c = rect.center();
    let h = size * 0.46;
    p.add(egui::Shape::convex_polygon(
        vec![pos2(c.x, c.y - h), pos2(c.x + h * 1.05, c.y + h * 0.85), pos2(c.x - h * 1.05, c.y + h * 0.85)],
        AMBER,
        Stroke::NONE,
    ));
    let ink = SHELL;
    p.line_segment([pos2(c.x, c.y - h * 0.35), pos2(c.x, c.y + h * 0.25)], Stroke::new(1.4, ink));
    p.circle_filled(pos2(c.x, c.y + h * 0.55), 0.9, ink);
}

/// Section header: title + a small "Optional" capsule badge — the Mac
/// `sectionCard` title row.
pub fn section_header(ui: &mut Ui, title: &str, optional: bool) {
    ui.horizontal(|ui| {
        ui.label(RichText::new(title).size(12.0).color(INK).strong());
        if optional {
            let font = FontId::proportional(9.0);
            let galley = ui.painter().layout_no_wrap("Optional".into(), font, INK3);
            let pad = vec2(6.0, 2.0);
            let (rect, _) = ui.allocate_exact_size(galley.size() + pad * 2.0, Sense::hover());
            ui.painter()
                .rect(rect, Rounding::same(rect.height() / 2.0), CONTROL, Stroke::NONE);
            ui.painter().galley(rect.min + pad, galley, INK3);
        }
    });
}

/// Draw the 5-bar waveform brand into a fixed-size clickable area. `t` is the
/// running clock (seconds), `active` animates the bars (recording), `color`
/// is white normally / red while quick-asking. Returns the click+drag response
/// so the caller can use it to toggle/drag the window.
pub fn waveform(ui: &mut Ui, t: f64, active: bool, color: Color32, box_size: f32) -> Response {
    const BARS: usize = 5;
    let bar_w = 2.5;
    let gap = 2.0;
    let max_h = 18.0_f32;
    let min_h = 4.0_f32;
    let idle = [5.0_f32, 10.0, 16.0, 10.0, 5.0];

    let (rect, resp) = ui.allocate_exact_size(Vec2::splat(box_size), Sense::click_and_drag());
    let hov = ui
        .ctx()
        .animate_bool_with_time(resp.id.with("hover"), resp.hovered(), HOVER_T);
    let painter = ui.painter_at(rect);
    let total_w = BARS as f32 * bar_w + (BARS as f32 - 1.0) * gap;
    let mut x = rect.center().x - total_w / 2.0;
    let cy = rect.center().y;
    let scale = 1.0 + 0.08 * hov;
    for (i, idle_h) in idle.iter().enumerate() {
        let h = if active {
            let phase = t * 2.4 + i as f64 * 0.5;
            min_h + (max_h - min_h) * (phase.sin().abs() as f32)
        } else {
            *idle_h
        } * scale;
        let bar = Rect::from_min_size(Pos2::new(x, cy - h / 2.0), vec2(bar_w, h));
        painter.rect_filled(bar, Rounding::same(bar_w / 2.0), color);
        x += bar_w + gap;
    }
    resp
}
