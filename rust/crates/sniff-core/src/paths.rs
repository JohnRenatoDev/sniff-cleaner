//! Path helpers: canonicalization that tolerates missing tails, containment
//! by components, and symlink-ancestor detection.

use std::path::{Component, Path, PathBuf};

/// `realpath`, or the canonical parent joined with the last component when
/// the path does not exist yet.
pub fn canonical(p: &Path) -> PathBuf {
    if let Ok(c) = std::fs::canonicalize(p) {
        return c;
    }
    match (p.parent(), p.file_name()) {
        (Some(parent), Some(name)) if parent != p => canonical(parent).join(name),
        _ => p.to_path_buf(),
    }
}

/// True when `path` equals `parent` or lies below it (component-wise).
pub fn contains(parent: &Path, path: &Path) -> bool {
    path.starts_with(parent)
}

/// True when any existing ancestor of `path` (excluding `path` itself) is a
/// symlink, or the path has `.`/`..` components.
pub fn has_symlink_ancestor(path: &Path) -> bool {
    let mut cur = PathBuf::new();
    let comps: Vec<Component> = path.components().collect();
    for (i, c) in comps.iter().enumerate() {
        match c {
            Component::RootDir => cur.push("/"),
            Component::Normal(n) => {
                cur.push(n);
                if i + 1 == comps.len() {
                    break;
                }
                if let Ok(m) = std::fs::symlink_metadata(&cur) {
                    if m.file_type().is_symlink() {
                        return true;
                    }
                }
            }
            _ => return true,
        }
    }
    false
}

pub fn is_symlink(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink())
}

/// Expands a leading `~/` with `home`.
pub fn expand_tilde(p: &str, home: &Path) -> PathBuf {
    if p == "~" {
        home.to_path_buf()
    } else if let Some(rest) = p.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(p)
    }
}

pub fn to_string(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}
