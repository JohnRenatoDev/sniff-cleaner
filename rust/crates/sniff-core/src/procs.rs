//! Visible process usage from `/proc`.
//!
//! For each process owned by the current user, Sniff reads the working
//! directory, root, executable, open file descriptors and mapped files, plus
//! the command line. Open objects are recorded by path and by device/inode, so
//! a hardlink opened through a path outside a candidate still counts as use.
//! Processes of other users are not inspectable without privileges; that limit
//! is reported. A process of the current user that cannot be read makes the
//! inventory incomplete, which blocks removal.

use crate::fsx::{EntryKind, Manifest};
use crate::model::Msg;
use crate::paths::contains;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct ProcessInfo {
    pub pid: i32,
    pub comm: String,
    /// Command line joined with spaces.
    pub command: String,
}

#[derive(Debug, Default, Clone)]
pub struct ProcessInventory {
    pub processes: Vec<ProcessInfo>,
    /// Paths of open files, working directories, executables and mappings.
    pub open_paths: Vec<PathBuf>,
    /// (dev, ino) of the same objects.
    pub open_inodes: HashSet<(u64, u64)>,
    /// Processes of the current user whose details could not be read.
    pub unreadable: Vec<(i32, String)>,
    /// Processes owned by other users (not inspected).
    pub other_users: usize,
    /// False when `/proc` itself could not be listed.
    pub listed: bool,
}

/// Helpers that systemd runs as the user but marks non-dumpable. They never
/// hold files in user caches or projects, so they do not make the inventory
/// incomplete. Anything else unreadable does.
const KNOWN_OPAQUE_HELPERS: &[&str] = &["(sd-pam)"];

impl ProcessInventory {
    pub fn is_complete(&self) -> bool {
        self.listed && self.unreadable.is_empty()
    }

    /// An empty, complete inventory (tests and fixtures).
    pub fn empty_complete() -> Self {
        ProcessInventory {
            listed: true,
            ..Default::default()
        }
    }

    pub fn capture() -> Self {
        Self::collect(Path::new("/proc"))
    }

    pub fn collect(proc_root: &Path) -> Self {
        let me = rustix::process::getuid().as_raw();
        let self_pid = std::process::id() as i32;
        let mut inv = ProcessInventory::default();
        let Ok(dir) = fs::read_dir(proc_root) else { return inv };
        inv.listed = true;
        let mut paths: HashSet<PathBuf> = HashSet::new();
        for entry in dir.flatten() {
            let name = entry.file_name();
            let Some(pid) = name.to_str().and_then(|s| s.parse::<i32>().ok()) else {
                continue;
            };
            if pid == self_pid {
                continue;
            }
            let base = entry.path();
            let Ok(meta) = fs::metadata(&base) else { continue };
            if meta.uid() != me {
                inv.other_users += 1;
                continue;
            }
            let comm = fs::read_to_string(base.join("comm"))
                .map(|s| s.trim().to_string())
                .unwrap_or_default();
            let command = fs::read(base.join("cmdline"))
                .map(|b| {
                    b.split(|c| *c == 0)
                        .filter(|s| !s.is_empty())
                        .map(|s| String::from_utf8_lossy(s).into_owned())
                        .collect::<Vec<_>>()
                        .join(" ")
                })
                .unwrap_or_default();
            let fds = match fs::read_dir(base.join("fd")) {
                Ok(it) => it,
                Err(_) => {
                    if base.join("comm").exists() && !KNOWN_OPAQUE_HELPERS.contains(&comm.as_str()) {
                        inv.unreadable.push((pid, comm));
                    }
                    continue;
                }
            };
            let mut objects: Vec<PathBuf> = fds.flatten().map(|fd| fd.path()).collect();
            objects.push(base.join("cwd"));
            objects.push(base.join("exe"));
            if fs::read_link(base.join("root")).is_ok_and(|r| r != Path::new("/")) {
                objects.push(base.join("root"));
            }
            for obj in objects {
                if let Ok(target) = fs::read_link(&obj) {
                    if target.is_absolute() {
                        paths.insert(target);
                    }
                }
                // metadata() follows the magic link to the open object itself.
                if let Ok(m) = fs::metadata(&obj) {
                    inv.open_inodes.insert((m.dev(), m.ino()));
                }
            }
            // Mapped files: shared libraries, native addons, mmapped caches.
            // Paths are stat'ed so devices compare like the manifest's do on
            // filesystems with per-subvolume device numbers.
            if let Ok(maps) = fs::read_to_string(base.join("maps")) {
                let mut mapped: HashSet<&str> = HashSet::new();
                for line in maps.lines() {
                    if let Some(idx) = line.find(" /") {
                        let p = line[idx + 1..].trim_end();
                        if !p.ends_with(" (deleted)") {
                            mapped.insert(p);
                        }
                    }
                }
                for p in mapped {
                    if let Ok(m) = fs::metadata(p) {
                        inv.open_inodes.insert((m.dev(), m.ino()));
                    }
                    paths.insert(PathBuf::from(p));
                }
            }
            inv.processes.push(ProcessInfo { pid, comm, command });
        }
        inv.open_paths = paths.into_iter().collect();
        inv
    }

    /// Why `path` must be kept because of visible process activity, if so.
    /// Checks, in order: inventory completeness, open paths inside `path`, a
    /// command line naming `path`, any manifest inode open elsewhere (catches
    /// hardlinks), and active tool tokens.
    pub fn reason(&self, path: &Path, tokens: &[&str], manifest: Option<&Manifest>) -> Option<Msg> {
        if !self.is_complete() {
            return Some(Msg::new("reason.process_inventory_incomplete"));
        }
        if self.open_paths.iter().any(|p| contains(path, p)) {
            return Some(Msg::new("reason.open_by_process"));
        }
        let needle = path.to_string_lossy();
        if self.processes.iter().any(|p| p.command.contains(needle.as_ref())) {
            return Some(Msg::new("reason.command_references"));
        }
        if let Some(m) = manifest {
            let hit = m
                .entries
                .iter()
                .any(|e| self.open_inodes.contains(&(e.id.dev, e.id.ino)));
            if hit {
                let linked = m.entries.iter().any(|e| {
                    e.id.kind != EntryKind::Dir && e.id.nlink > 1 && self.open_inodes.contains(&(e.id.dev, e.id.ino))
                });
                return Some(Msg::new(if linked {
                    "reason.hardlink_open"
                } else {
                    "reason.open_by_process"
                }));
            }
        }
        for token in tokens {
            let t = token.to_lowercase();
            if self.processes.iter().any(|p| p.command.to_lowercase().contains(&t)) {
                return Some(Msg::new("reason.active_tool").arg(token.trim()));
            }
        }
        None
    }

    /// True when a supported build appears to be running.
    pub fn build_in_progress(&self, tokens: &[&str]) -> bool {
        self.processes.iter().any(|p| {
            let c = p.command.to_lowercase();
            tokens.iter().any(|t| c.contains(&t.to_lowercase()))
        })
    }

    pub fn summary(&self) -> HashMap<&'static str, usize> {
        HashMap::from([
            ("visible", self.processes.len()),
            ("unreadable", self.unreadable.len()),
            ("other_users", self.other_users),
        ])
    }
}
