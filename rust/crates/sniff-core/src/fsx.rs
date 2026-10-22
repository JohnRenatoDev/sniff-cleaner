//! Descriptor-relative filesystem primitives.
//!
//! Every traversal starts from `/` and opens one component at a time with
//! `O_NOFOLLOW | O_DIRECTORY`, so a symlinked ancestor is refused instead of
//! followed. Inside a candidate, entries are read with `fstatat(AT_SYMLINK_NOFOLLOW)`
//! and removed with `unlinkat` relative to their parent descriptor. Internal
//! symlinks are recorded and removed as links; their targets are never read.

use rustix::fd::{AsFd, OwnedFd};
use rustix::fs::{openat, statat, unlinkat, AtFlags, Dir, FileType, Mode, OFlags, Stat, CWD};
use rustix::io::Errno;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashSet};
use std::ffi::{CStr, CString};
use std::path::{Component, Path, PathBuf};

/// Directories deeper than this are not walked; the manifest becomes partial.
pub const MAX_DEPTH: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    File,
    Dir,
    Symlink,
    Other,
}

impl EntryKind {
    pub fn from_stat(st: &Stat) -> Self {
        match FileType::from_raw_mode(st.st_mode) {
            FileType::RegularFile => EntryKind::File,
            FileType::Directory => EntryKind::Dir,
            FileType::Symlink => EntryKind::Symlink,
            _ => EntryKind::Other,
        }
    }
}

/// Identity and metadata of one filesystem entry, as recorded at scan time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    pub dev: u64,
    pub ino: u64,
    pub kind: EntryKind,
    pub size: u64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
    pub nlink: u64,
    pub uid: u32,
    pub mode: u32,
}

impl Identity {
    pub fn from_stat(st: &Stat) -> Self {
        Identity {
            dev: st.st_dev,
            ino: st.st_ino,
            kind: EntryKind::from_stat(st),
            size: st.st_size.max(0) as u64,
            mtime_ns: st
                .st_mtime
                .saturating_mul(1_000_000_000)
                .saturating_add(st.st_mtime_nsec as i64),
            ctime_ns: st
                .st_ctime
                .saturating_mul(1_000_000_000)
                .saturating_add(st.st_ctime_nsec as i64),
            nlink: st.st_nlink,
            uid: st.st_uid,
            mode: st.st_mode,
        }
    }

    /// Check used while removing, after the strict comparison passed.
    /// Directory times and link counts change as their children go. A
    /// hardlinked file's link count and ctime change when this operation
    /// removes one of its other links inside the candidate; its link count
    /// may only shrink. Everything else must be identical.
    pub fn matches_during_removal(&self, current: &Identity) -> bool {
        if self.dev != current.dev || self.ino != current.ino || self.kind != current.kind || self.uid != current.uid {
            return false;
        }
        if self.kind == EntryKind::Dir {
            return true;
        }
        if self.size != current.size || self.mtime_ns != current.mtime_ns || self.mode != current.mode {
            return false;
        }
        if self.nlink > 1 {
            current.nlink <= self.nlink
        } else {
            current.nlink == self.nlink && current.ctime_ns == self.ctime_ns
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestEntry {
    /// Path relative to the candidate root, `/`-separated. Empty for the root.
    pub path: String,
    pub id: Identity,
    /// Allocated bytes (`st_blocks * 512`).
    pub allocated: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PartialReason {
    EntryLimit,
    DepthLimit,
    CrossesFilesystem,
    PermissionDenied,
    NonUtf8Name,
    ReadError,
    Changed,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Manifest {
    pub entries: Vec<ManifestEntry>,
    /// `None` means the walk visited every entry under the root.
    pub partial: Option<PartialReason>,
    pub logical_bytes: u64,
    pub allocated_bytes: u64,
    /// Regular files with more than one link (counted once per inode).
    pub hardlinked_files: u64,
    /// Inodes whose links reach outside the candidate (link count larger
    /// than the links seen here). Removing them does not free their blocks.
    pub externally_linked_files: u64,
    pub newest_mtime_ns: i64,
}

impl Manifest {
    pub fn is_complete(&self) -> bool {
        self.partial.is_none()
    }

    pub fn root(&self) -> Option<&ManifestEntry> {
        self.entries.first().filter(|e| e.path.is_empty())
    }

    pub fn inodes(&self) -> HashSet<(u64, u64)> {
        self.entries.iter().map(|e| (e.id.dev, e.id.ino)).collect()
    }
}

#[derive(Debug)]
pub enum OpenError {
    NotAbsolute,
    SymlinkAncestor(PathBuf),
    NotFound,
    Denied,
    Other(Errno),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpenError::NotAbsolute => write!(f, "path is not absolute"),
            OpenError::SymlinkAncestor(p) => write!(f, "symlink in path: {}", p.display()),
            OpenError::NotFound => write!(f, "not found"),
            OpenError::Denied => write!(f, "permission denied"),
            OpenError::Other(e) => write!(f, "{e}"),
        }
    }
}

fn map_errno(e: Errno, at: &Path) -> OpenError {
    match e {
        Errno::LOOP | Errno::NOTDIR => OpenError::SymlinkAncestor(at.to_path_buf()),
        Errno::NOENT => OpenError::NotFound,
        Errno::ACCESS | Errno::PERM => OpenError::Denied,
        other => OpenError::Other(other),
    }
}

fn dir_flags() -> OFlags {
    OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC
}

/// Opens an absolute directory path one component at a time without
/// following any symlink. `..` components are refused.
pub fn open_dir_nofollow(path: &Path) -> Result<OwnedFd, OpenError> {
    if !path.is_absolute() {
        return Err(OpenError::NotAbsolute);
    }
    let mut fd = openat(CWD, "/", dir_flags(), Mode::empty()).map_err(|e| map_errno(e, Path::new("/")))?;
    let mut walked = PathBuf::from("/");
    for comp in path.components() {
        match comp {
            Component::RootDir => continue,
            Component::CurDir => continue,
            Component::Normal(name) => {
                walked.push(name);
                fd = openat(&fd, name, dir_flags(), Mode::empty()).map_err(|e| map_errno(e, &walked))?;
            }
            _ => return Err(OpenError::SymlinkAncestor(walked)),
        }
    }
    Ok(fd)
}

/// Opens the parent directory of `path` and returns it with the final name.
pub fn open_parent_nofollow(path: &Path) -> Result<(OwnedFd, CString), OpenError> {
    let parent = path.parent().ok_or(OpenError::NotAbsolute)?;
    let name = path.file_name().ok_or(OpenError::NotAbsolute)?;
    let fd = open_dir_nofollow(parent)?;
    let cname = CString::new(name.as_encoded_bytes()).map_err(|_| OpenError::NotAbsolute)?;
    Ok((fd, cname))
}

/// `lstat` of an absolute path with every ancestor opened without following
/// symlinks. The final component itself may be a symlink.
pub fn lstat_nofollow(path: &Path) -> Result<Stat, OpenError> {
    let (parent, name) = open_parent_nofollow(path)?;
    statat(&parent, name.as_c_str(), AtFlags::SYMLINK_NOFOLLOW).map_err(|e| match e {
        Errno::NOENT => OpenError::NotFound,
        Errno::ACCESS | Errno::PERM => OpenError::Denied,
        other => OpenError::Other(other),
    })
}

pub struct WalkOptions {
    pub max_entries: usize,
    /// Directory names that are not descended into; they are still recorded
    /// as a single entry and make the manifest partial if `skip_is_partial`.
    pub stop_at_dev_change: bool,
}

impl Default for WalkOptions {
    fn default() -> Self {
        WalkOptions {
            max_entries: 500_000,
            stop_at_dev_change: true,
        }
    }
}

struct Frame {
    dir: Dir,
    prefix: String,
    depth: usize,
}

/// Records a manifest of everything under `path`, which must be a directory
/// reached without symlinks. Never follows symlinks and never crosses into
/// another filesystem. Stops early, marking the manifest partial, when a limit
/// is reached or an entry cannot be read.
pub fn build_manifest(path: &Path, opts: &WalkOptions) -> Result<Manifest, OpenError> {
    let root_fd = open_dir_nofollow(path)?;
    let root_stat = rustix::fs::fstat(&root_fd).map_err(OpenError::Other)?;
    let mut m = Manifest::default();
    let mut seen_inodes: HashSet<(u64, u64)> = HashSet::new();
    let mut link_counts: std::collections::HashMap<(u64, u64), (u64, u64)> = Default::default();
    record(&mut m, String::new(), &root_stat, &mut seen_inodes, &mut link_counts);

    let dir = match Dir::read_from(&root_fd) {
        Ok(d) => d,
        Err(Errno::ACCESS) | Err(Errno::PERM) => {
            m.partial = Some(PartialReason::PermissionDenied);
            return Ok(m);
        }
        Err(e) => return Err(OpenError::Other(e)),
    };
    let mut stack = vec![Frame {
        dir,
        prefix: String::new(),
        depth: 1,
    }];
    'walk: while let Some(frame) = stack.last_mut() {
        let next = frame.dir.read();
        let entry = match next {
            None => {
                stack.pop();
                continue;
            }
            Some(Err(_)) => {
                m.partial = Some(PartialReason::ReadError);
                break;
            }
            Some(Ok(e)) => e,
        };
        let name = entry.file_name();
        if name == c"." || name == c".." {
            continue;
        }
        let Ok(name_str) = name.to_str() else {
            m.partial = Some(PartialReason::NonUtf8Name);
            break;
        };
        if m.entries.len() >= opts.max_entries {
            m.partial = Some(PartialReason::EntryLimit);
            break;
        }
        let parent_fd = match frame.dir.fd() {
            Ok(fd) => fd,
            Err(_) => {
                m.partial = Some(PartialReason::ReadError);
                break;
            }
        };
        let st = match statat(parent_fd, name, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(st) => st,
            Err(Errno::NOENT) => {
                m.partial = Some(PartialReason::Changed);
                break;
            }
            Err(Errno::ACCESS) | Err(Errno::PERM) => {
                m.partial = Some(PartialReason::PermissionDenied);
                break;
            }
            Err(_) => {
                m.partial = Some(PartialReason::ReadError);
                break;
            }
        };
        let rel = if frame.prefix.is_empty() {
            name_str.to_string()
        } else {
            format!("{}/{}", frame.prefix, name_str)
        };
        let kind = EntryKind::from_stat(&st);
        if kind == EntryKind::Dir && opts.stop_at_dev_change && st.st_dev != root_stat.st_dev {
            m.partial = Some(PartialReason::CrossesFilesystem);
            break;
        }
        record(&mut m, rel.clone(), &st, &mut seen_inodes, &mut link_counts);
        if kind == EntryKind::Dir {
            let depth = frame.depth;
            if depth >= MAX_DEPTH {
                m.partial = Some(PartialReason::DepthLimit);
                break 'walk;
            }
            let child = match openat(parent_fd, name, dir_flags(), Mode::empty()) {
                Ok(fd) => fd,
                Err(Errno::ACCESS) | Err(Errno::PERM) => {
                    m.partial = Some(PartialReason::PermissionDenied);
                    break;
                }
                Err(_) => {
                    m.partial = Some(PartialReason::Changed);
                    break;
                }
            };
            // The directory opened must be the one just recorded.
            match rustix::fs::fstat(&child) {
                Ok(cst) if cst.st_ino == st.st_ino && cst.st_dev == st.st_dev => {}
                _ => {
                    m.partial = Some(PartialReason::Changed);
                    break;
                }
            }
            match Dir::new(child) {
                Ok(d) => stack.push(Frame {
                    dir: d,
                    prefix: rel,
                    depth: depth + 1,
                }),
                Err(_) => {
                    m.partial = Some(PartialReason::ReadError);
                    break;
                }
            }
        }
    }
    for ((_, _), (nlink, seen)) in link_counts {
        if nlink > 1 {
            m.hardlinked_files += 1;
            if nlink > seen {
                m.externally_linked_files += 1;
            }
        }
    }
    Ok(m)
}

fn record(
    m: &mut Manifest,
    rel: String,
    st: &Stat,
    seen: &mut HashSet<(u64, u64)>,
    links: &mut std::collections::HashMap<(u64, u64), (u64, u64)>,
) {
    let id = Identity::from_stat(st);
    let key = (id.dev, id.ino);
    let allocated = (st.st_blocks as u64).saturating_mul(512);
    if seen.insert(key) {
        if id.kind == EntryKind::File {
            m.logical_bytes += id.size;
        }
        m.allocated_bytes += allocated;
    }
    if id.kind == EntryKind::File {
        let e = links.entry(key).or_insert((id.nlink, 0));
        e.1 += 1;
    }
    if id.mtime_ns > m.newest_mtime_ns {
        m.newest_mtime_ns = id.mtime_ns;
    }
    m.entries.push(ManifestEntry {
        path: rel,
        id,
        allocated,
    });
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RemovalReport {
    pub removed_entries: u64,
    pub removed_logical_bytes: u64,
    pub removed_allocated_bytes: u64,
    /// True when every manifest entry, including the root, is gone.
    pub complete: bool,
    /// First reason removal stopped, if it did.
    pub stopped: Option<RemovalStop>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "reason", rename_all = "snake_case")]
pub enum RemovalStop {
    /// The root path could not be opened safely.
    Unreachable { detail: String },
    /// A file or directory appeared that is not in the manifest.
    NewEntry { path: String },
    /// An entry's identity or content markers differ from the manifest.
    Changed { path: String },
    /// An entry in the manifest is missing.
    Missing { path: String },
    /// The manifest is partial and can never authorize removal.
    PartialManifest,
    /// unlinkat failed.
    Failed { path: String, errno: i32 },
}

/// Compares the tree under `path` with `manifest` without changing anything.
/// Returns the first difference, or `None` when they match exactly.
pub fn verify_manifest(path: &Path, manifest: &Manifest) -> Option<RemovalStop> {
    if !manifest.is_complete() {
        return Some(RemovalStop::PartialManifest);
    }
    let current = match build_manifest(
        path,
        &WalkOptions {
            max_entries: manifest.entries.len() + 1,
            stop_at_dev_change: true,
        },
    ) {
        Ok(m) => m,
        Err(e) => return Some(RemovalStop::Unreachable { detail: e.to_string() }),
    };
    if current.partial == Some(PartialReason::EntryLimit) {
        let known: BTreeSet<&str> = manifest.entries.iter().map(|e| e.path.as_str()).collect();
        let extra = current
            .entries
            .iter()
            .find(|e| !known.contains(e.path.as_str()))
            .map(|e| e.path.clone())
            .unwrap_or_default();
        return Some(RemovalStop::NewEntry { path: extra });
    }
    if current.partial.is_some() {
        return Some(RemovalStop::Changed { path: String::new() });
    }
    compare_manifests(manifest, &current)
}

pub fn compare_manifests(expected: &Manifest, current: &Manifest) -> Option<RemovalStop> {
    let mut by_path: std::collections::HashMap<&str, &ManifestEntry> =
        current.entries.iter().map(|e| (e.path.as_str(), e)).collect();
    for e in &expected.entries {
        match by_path.remove(e.path.as_str()) {
            None => return Some(RemovalStop::Missing { path: e.path.clone() }),
            Some(cur) if e.id != cur.id => {
                return Some(RemovalStop::Changed { path: e.path.clone() });
            }
            Some(_) => {}
        }
    }
    if let Some((p, _)) = by_path.into_iter().next() {
        return Some(RemovalStop::NewEntry { path: p.to_string() });
    }
    None
}

/// Removes exactly the entries in `manifest` under `path`, children first,
/// re-checking each entry's identity immediately before `unlinkat`. Anything
/// not in the manifest stops the operation. `last` names a top-level entry to
/// remove after everything else (a worktree's `.git` file), so a failure
/// leaves the Git link in place.
pub fn remove_manifest(path: &Path, manifest: &Manifest, last: Option<&str>) -> RemovalReport {
    remove_manifest_with_hook(path, manifest, last, &mut |_| {})
}

/// Same as [`remove_manifest`], calling `hook` with each relative path right
/// before it is unlinked. Tests use it to simulate concurrent changes.
pub fn remove_manifest_with_hook(
    path: &Path,
    manifest: &Manifest,
    last: Option<&str>,
    hook: &mut dyn FnMut(&str),
) -> RemovalReport {
    let mut report = RemovalReport::default();
    if !manifest.is_complete() {
        report.stopped = Some(RemovalStop::PartialManifest);
        return report;
    }
    let Some(root) = manifest.root() else {
        report.stopped = Some(RemovalStop::PartialManifest);
        return report;
    };
    let (parent_fd, root_name) = match open_parent_nofollow(path) {
        Ok(v) => v,
        Err(e) => {
            report.stopped = Some(RemovalStop::Unreachable { detail: e.to_string() });
            return report;
        }
    };
    match statat(&parent_fd, root_name.as_c_str(), AtFlags::SYMLINK_NOFOLLOW) {
        Ok(st) if root.id.matches_during_removal(&Identity::from_stat(&st)) => {}
        Ok(_) => {
            report.stopped = Some(RemovalStop::Changed { path: String::new() });
            return report;
        }
        Err(e) => {
            report.stopped = Some(RemovalStop::Unreachable { detail: e.to_string() });
            return report;
        }
    }
    let root_fd = match openat(&parent_fd, root_name.as_c_str(), dir_flags(), Mode::empty()) {
        Ok(fd) => fd,
        Err(e) => {
            report.stopped = Some(RemovalStop::Unreachable { detail: e.to_string() });
            return report;
        }
    };
    match rustix::fs::fstat(&root_fd) {
        Ok(st) if st.st_ino == root.id.ino && st.st_dev == root.id.dev => {}
        _ => {
            report.stopped = Some(RemovalStop::Changed { path: String::new() });
            return report;
        }
    }

    let expected: std::collections::HashMap<&str, &ManifestEntry> =
        manifest.entries.iter().map(|e| (e.path.as_str(), e)).collect();
    let mut removed_inodes: HashSet<(u64, u64)> = HashSet::new();
    if let Err(stop) = remove_children(&root_fd, "", &expected, last, &mut report, &mut removed_inodes, hook) {
        report.stopped = Some(stop);
        return report;
    }
    if let Some(last_name) = last {
        if let Some(entry) = expected.get(last_name) {
            if let Err(stop) = remove_one(
                &root_fd,
                last_name,
                last_name,
                entry,
                &mut report,
                &mut removed_inodes,
                hook,
            ) {
                report.stopped = Some(stop);
                return report;
            }
        }
    }
    let root_entry = ManifestEntry {
        path: String::new(),
        id: root.id.clone(),
        allocated: root.allocated,
    };
    drop(root_fd);
    if let Err(stop) = remove_one(
        &parent_fd,
        root_name.to_str().unwrap_or(""),
        "",
        &root_entry,
        &mut report,
        &mut removed_inodes,
        hook,
    ) {
        report.stopped = Some(stop);
        return report;
    }
    report.complete = true;
    report
}

fn remove_children(
    dir_fd: &OwnedFd,
    prefix: &str,
    expected: &std::collections::HashMap<&str, &ManifestEntry>,
    last: Option<&str>,
    report: &mut RemovalReport,
    removed: &mut HashSet<(u64, u64)>,
    hook: &mut dyn FnMut(&str),
) -> Result<(), RemovalStop> {
    // Collect names first; removing while iterating a directory stream is
    // allowed but makes the listing order unspecified.
    let mut names: Vec<CString> = Vec::new();
    let dup = rustix::io::dup(dir_fd).map_err(|e| RemovalStop::Failed {
        path: prefix.to_string(),
        errno: e.raw_os_error(),
    })?;
    let mut dir = Dir::new(dup).map_err(|e| RemovalStop::Failed {
        path: prefix.to_string(),
        errno: e.raw_os_error(),
    })?;
    for entry in dir.by_ref() {
        let entry = entry.map_err(|e| RemovalStop::Failed {
            path: prefix.to_string(),
            errno: e.raw_os_error(),
        })?;
        let name = entry.file_name();
        if name == c"." || name == c".." {
            continue;
        }
        names.push(name.to_owned());
    }
    for name in names {
        let Ok(name_str) = name.to_str() else {
            return Err(RemovalStop::NewEntry {
                path: format!("{prefix}/<non-utf8>"),
            });
        };
        let rel = if prefix.is_empty() {
            name_str.to_string()
        } else {
            format!("{prefix}/{name_str}")
        };
        if prefix.is_empty() && Some(name_str) == last {
            continue;
        }
        let Some(entry) = expected.get(rel.as_str()) else {
            return Err(RemovalStop::NewEntry { path: rel });
        };
        if entry.id.kind == EntryKind::Dir {
            let st = statat(dir_fd, name.as_c_str(), AtFlags::SYMLINK_NOFOLLOW)
                .map_err(|_| RemovalStop::Missing { path: rel.clone() })?;
            if !entry.id.matches_during_removal(&Identity::from_stat(&st)) {
                return Err(RemovalStop::Changed { path: rel });
            }
            let child = openat(dir_fd, name.as_c_str(), dir_flags(), Mode::empty())
                .map_err(|_| RemovalStop::Changed { path: rel.clone() })?;
            let cst = rustix::fs::fstat(&child).map_err(|_| RemovalStop::Changed { path: rel.clone() })?;
            if cst.st_ino != entry.id.ino || cst.st_dev != entry.id.dev {
                return Err(RemovalStop::Changed { path: rel });
            }
            remove_children(&child, &rel, expected, None, report, removed, hook)?;
        }
        remove_one(dir_fd, name_str, &rel, entry, report, removed, hook)?;
    }
    Ok(())
}

fn remove_one(
    dir_fd: &OwnedFd,
    name: &str,
    rel: &str,
    entry: &ManifestEntry,
    report: &mut RemovalReport,
    removed: &mut HashSet<(u64, u64)>,
    hook: &mut dyn FnMut(&str),
) -> Result<(), RemovalStop> {
    hook(rel);
    let st = match statat(dir_fd, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(st) => st,
        Err(_) => return Err(RemovalStop::Missing { path: rel.to_string() }),
    };
    if !entry.id.matches_during_removal(&Identity::from_stat(&st)) {
        return Err(RemovalStop::Changed { path: rel.to_string() });
    }
    let flags = if entry.id.kind == EntryKind::Dir {
        AtFlags::REMOVEDIR
    } else {
        AtFlags::empty()
    };
    if let Err(e) = unlinkat(dir_fd, name, flags) {
        return Err(RemovalStop::Failed {
            path: rel.to_string(),
            errno: e.raw_os_error(),
        });
    }
    report.removed_entries += 1;
    let key = (entry.id.dev, entry.id.ino);
    // A hardlinked inode is freed only when its last link goes; count its
    // bytes once, when the final link inside the candidate is removed.
    if st.st_nlink <= 1 && removed.insert(key) {
        if entry.id.kind == EntryKind::File {
            report.removed_logical_bytes += entry.id.size;
        }
        report.removed_allocated_bytes += entry.allocated;
    }
    Ok(())
}

/// Free bytes available to the user on the filesystem holding `path`.
pub fn available_bytes(path: &Path) -> Option<u64> {
    let fd = open_dir_nofollow(path).ok()?;
    let s = rustix::fs::fstatvfs(fd.as_fd()).ok()?;
    Some(s.f_bavail.saturating_mul(s.f_frsize))
}

pub fn cstr_to_string(c: &CStr) -> String {
    c.to_string_lossy().into_owned()
}
