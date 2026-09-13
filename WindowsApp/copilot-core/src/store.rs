//! Shared JSON persistence + id generation for the preset libraries.
//!
//! Port of the macOS `JSONStore`: each library is one JSON file next to
//! `config.json` in the app's config directory. Loading never fails — a
//! missing or corrupt file yields the default — so a bad write can't stop
//! the overlay from starting mid-interview.

use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::Serialize;

/// Process-wide override for [`config_dir`], set once at startup.
static CONFIG_DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// Point every config and library file at `dir` instead of the OS config
/// directory. Used by the UI-gallery mode so a demo run can't touch the
/// user's real settings, prompts, or résumés. First call wins.
pub fn set_config_dir(dir: PathBuf) {
    let _ = CONFIG_DIR.set(dir);
}

/// Directory holding `config.json` and every library file.
pub fn config_dir() -> PathBuf {
    if let Some(dir) = CONFIG_DIR.get() {
        return dir.clone();
    }
    dirs::config_dir().unwrap_or_else(|| PathBuf::from(".")).join("thecloser")
}

/// Path of a library file inside the config directory.
pub fn library_path(filename: &str) -> PathBuf {
    config_dir().join(filename)
}

pub fn load<T: DeserializeOwned + Default>(path: &Path) -> T {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

/// Write atomically: serialize to a sibling temp file, then rename over the
/// target, so an interrupted write can't truncate an existing library.
pub fn save<T: Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(value).map_err(std::io::Error::other)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, path)
}

/// A unique, sortable id. Microseconds since the epoch, bumped when it would
/// collide, so ids stay unique within a run and readable in the JSON.
pub fn new_id() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0);
    LAST.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |prev| Some(now.max(prev + 1)))
        .unwrap_or(now)
}

/// Seconds since the epoch — the `created_at` / `updated_at` stamp.
pub fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_increasing() {
        let a = new_id();
        let b = new_id();
        let c = new_id();
        assert!(a < b && b < c);
    }

    #[test]
    fn round_trips_and_survives_corruption() {
        let dir = std::env::temp_dir().join(format!("tc-store-{}", std::process::id()));
        let path = dir.join("things.json");
        save(&path, &vec![1u32, 2, 3]).unwrap();
        let back: Vec<u32> = load(&path);
        assert_eq!(back, vec![1, 2, 3]);

        std::fs::write(&path, b"{ not json").unwrap();
        let back: Vec<u32> = load(&path);
        assert!(back.is_empty(), "corrupt library must fall back to default");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_file_yields_default() {
        let back: Vec<u32> = load(Path::new("/nonexistent/thecloser/nope.json"));
        assert!(back.is_empty());
    }
}
