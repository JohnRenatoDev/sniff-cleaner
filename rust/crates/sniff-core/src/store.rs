//! Private persistence under the XDG base directories.
//!
//! - settings: `$XDG_CONFIG_HOME/sniff/settings.json`
//! - history, scheduler state and the shared lock: `$XDG_STATE_HOME/sniff/`
//!
//! Directories are created with mode 0700 and files with 0600. Writes go to a
//! temporary file in the same directory, are fsynced and renamed into place,
//! then the directory is fsynced. A file that exists but cannot be parsed is
//! reported as corrupt and never overwritten implicitly.

use rustix::fs::{flock, FlockOperation};
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Dirs {
    pub home: PathBuf,
    pub config: PathBuf,
    pub state: PathBuf,
    pub cache_home: PathBuf,
    pub data_home: PathBuf,
}

#[derive(Debug)]
pub enum StoreError {
    Io(PathBuf, std::io::Error),
    Corrupt(PathBuf, String),
    Insecure(PathBuf),
    Busy,
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Io(p, e) => write!(f, "{}: {e}", p.display()),
            StoreError::Corrupt(p, e) => write!(f, "{}: {e}", p.display()),
            StoreError::Insecure(p) => write!(f, "{}: not a private regular file owned by you", p.display()),
            StoreError::Busy => write!(f, "another Sniff operation holds the lock"),
        }
    }
}

fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).map(PathBuf::from).filter(|p| p.is_absolute())
}

impl Dirs {
    /// Resolves directories from the environment. `SNIFF_HOME` replaces `HOME`
    /// (and the XDG variables derived from it) for fixtures and tests.
    pub fn from_env() -> Option<Self> {
        if let Some(home) = env_dir("SNIFF_HOME") {
            return Some(Self::for_home(&home));
        }
        let home = env_dir("HOME")?;
        Some(Dirs {
            config: env_dir("XDG_CONFIG_HOME")
                .unwrap_or_else(|| home.join(".config"))
                .join("sniff"),
            state: env_dir("XDG_STATE_HOME")
                .unwrap_or_else(|| home.join(".local/state"))
                .join("sniff"),
            cache_home: env_dir("XDG_CACHE_HOME").unwrap_or_else(|| home.join(".cache")),
            data_home: env_dir("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share")),
            home,
        })
    }

    pub fn for_home(home: &Path) -> Self {
        Dirs {
            home: home.to_path_buf(),
            config: home.join(".config/sniff"),
            state: home.join(".local/state/sniff"),
            cache_home: home.join(".cache"),
            data_home: home.join(".local/share"),
        }
    }

    pub fn settings_file(&self) -> PathBuf {
        self.config.join("settings.json")
    }
    /// Last scan, cleanup history and scheduler state.
    pub fn history_file(&self) -> PathBuf {
        self.state.join("state.json")
    }
    pub fn lock_file(&self) -> PathBuf {
        self.state.join("sniff.lock")
    }
}

pub fn ensure_private_dir(dir: &Path) -> Result<(), StoreError> {
    if !dir.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(|e| StoreError::Io(dir.to_path_buf(), e))?;
    }
    let meta = fs::symlink_metadata(dir).map_err(|e| StoreError::Io(dir.to_path_buf(), e))?;
    if !meta.is_dir() {
        return Err(StoreError::Insecure(dir.to_path_buf()));
    }
    if meta.permissions().mode() & 0o077 != 0 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
            .map_err(|e| StoreError::Io(dir.to_path_buf(), e))?;
    }
    Ok(())
}

/// Reads JSON. `Ok(None)` when the file does not exist.
pub fn read_json<T: DeserializeOwned>(path: &Path) -> Result<Option<T>, StoreError> {
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(StoreError::Io(path.to_path_buf(), e)),
    };
    if !meta.is_file() {
        return Err(StoreError::Insecure(path.to_path_buf()));
    }
    let bytes = fs::read(path).map_err(|e| StoreError::Io(path.to_path_buf(), e))?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|e| StoreError::Corrupt(path.to_path_buf(), e.to_string()))
}

/// Atomically replaces `path` with the JSON encoding of `value`, mode 0600.
pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<(), StoreError> {
    let dir = path.parent().ok_or_else(|| StoreError::Insecure(path.to_path_buf()))?;
    ensure_private_dir(dir)?;
    let mut data =
        serde_json::to_vec_pretty(value).map_err(|e| StoreError::Corrupt(path.to_path_buf(), e.to_string()))?;
    data.push(b'\n');
    write_atomic(path, &data)
}

pub fn write_atomic(path: &Path, data: &[u8]) -> Result<(), StoreError> {
    let dir = path.parent().ok_or_else(|| StoreError::Insecure(path.to_path_buf()))?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = dir.join(format!(".{name}.tmp-{}", std::process::id()));
    let io = |e| StoreError::Io(tmp.clone(), e);
    {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&tmp)
            .map_err(io)?;
        f.write_all(data).map_err(|e| StoreError::Io(tmp.clone(), e))?;
        f.sync_all().map_err(|e| StoreError::Io(tmp.clone(), e))?;
    }
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return Err(StoreError::Io(path.to_path_buf(), e));
    }
    if let Ok(d) = File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(())
}

/// Writes JSON only when the current file (if any) is readable, so corrupt or
/// unexpected state is never replaced silently.
pub fn save_validated<T: Serialize + DeserializeOwned>(path: &Path, value: &T) -> Result<(), StoreError> {
    let _existing: Option<T> = read_json(path)?;
    write_json(path, value)
}

pub fn load_prefs(dirs: &Dirs) -> Result<crate::model::Preferences, StoreError> {
    Ok(read_json(&dirs.settings_file())?.unwrap_or_default())
}

pub fn save_prefs(dirs: &Dirs, prefs: &crate::model::Preferences) -> Result<(), StoreError> {
    ensure_private_dir(&dirs.config)?;
    save_validated(&dirs.settings_file(), prefs)
}

pub fn load_state(dirs: &Dirs) -> Result<crate::model::PersistedState, StoreError> {
    let state: Option<crate::model::PersistedState> = read_json(&dirs.history_file())?;
    Ok(state.unwrap_or(crate::model::PersistedState {
        schema_version: 1,
        ..Default::default()
    }))
}

/// Manifests of the last scan's candidates, kept apart from `state.json` so
/// listing and status stay fast. Only `plan` needs them.
#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct ManifestBundle {
    pub scan_date: i64,
    pub manifests: std::collections::BTreeMap<String, crate::fsx::Manifest>,
}

impl Dirs {
    pub fn manifests_file(&self) -> PathBuf {
        self.state.join("scan-manifests.json")
    }
}

/// Loads the state and reattaches manifests recorded for the same scan.
/// Manifests from another scan are ignored, leaving items unplannable.
pub fn load_state_with_manifests(dirs: &Dirs) -> Result<crate::model::PersistedState, StoreError> {
    let mut state = load_state(dirs)?;
    let Some(scan) = state.last_scan.as_mut() else {
        return Ok(state);
    };
    let bundle: Option<ManifestBundle> = read_json(&dirs.manifests_file())?;
    if let Some(mut b) = bundle.filter(|b| b.scan_date == scan.date) {
        for f in &mut scan.findings {
            if let Some(m) = b.manifests.remove(&f.path) {
                f.manifest = m;
            }
        }
    }
    Ok(state)
}

/// Saves the state. Manifests in the last scan go to the manifest bundle; the
/// bundle is rewritten only when the scan carries manifests (a fresh scan),
/// so saving a reloaded state never discards them.
pub fn save_state(dirs: &Dirs, state: &crate::model::PersistedState) -> Result<(), StoreError> {
    ensure_private_dir(&dirs.state)?;
    let mut slim = state.clone();
    if let Some(scan) = slim.last_scan.as_mut() {
        let mut bundle = ManifestBundle {
            scan_date: scan.date,
            ..Default::default()
        };
        for f in &mut scan.findings {
            if !f.manifest.entries.is_empty() {
                bundle.manifests.insert(f.path.clone(), std::mem::take(&mut f.manifest));
            }
        }
        if !bundle.manifests.is_empty() {
            save_validated(&dirs.manifests_file(), &bundle)?;
        }
    }
    save_validated(&dirs.history_file(), &slim)
}

/// Exclusive advisory lock shared by the plugin, CLI and scheduler. Released
/// on drop.
pub struct OperationLock {
    _file: File,
}

impl OperationLock {
    pub fn acquire(dirs: &Dirs, wait: bool) -> Result<Self, StoreError> {
        ensure_private_dir(&dirs.state)?;
        let path = dirs.lock_file();
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32)
            .open(&path)
            .map_err(|e| StoreError::Io(path.clone(), e))?;
        let op = if wait {
            FlockOperation::LockExclusive
        } else {
            FlockOperation::NonBlockingLockExclusive
        };
        match flock(&file, op) {
            Ok(()) => Ok(OperationLock { _file: file }),
            Err(rustix::io::Errno::WOULDBLOCK) => Err(StoreError::Busy),
            Err(e) => Err(StoreError::Io(path, e.into())),
        }
    }
}

/// Seconds since the Unix epoch.
pub fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// RFC 3339 UTC timestamp for display and JSON.
pub fn rfc3339(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3339_known_dates() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(1_792_627_200), "2026-10-22T00:00:00Z");
    }
}
