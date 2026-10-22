//! Text and JSON presentation. JSON keys and identifiers are stable across
//! languages; human-readable fields are localized.

use serde_json::{json, Value};
use sniff_core::catalog::Catalog;
use sniff_core::i18n::{self, Lang};
use sniff_core::model::*;
use sniff_core::schedule::Registration;
use sniff_core::store::rfc3339;
use std::path::Path;

pub struct Out {
    pub json: bool,
    pub lang: Lang,
}

fn print_json(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
}

impl Out {
    fn t(&self, k: &str) -> String {
        i18n::text(self.lang, k)
    }
    fn r(&self, m: &Msg) -> String {
        i18n::render(self.lang, m)
    }
    fn bytes(&self, n: u64) -> String {
        i18n::format_bytes(self.lang, n)
    }

    pub fn summary(&self, f: &Finding) -> Value {
        let mut v = json!({
            "path": f.path,
            "category": f.category.cli_name(),
            "categoryTitle": self.t(&f.category.title_key()),
            "state": f.state.raw(),
            "stateTitle": self.t(&format!("state.{}", f.state.raw())),
            "title": self.r(&f.title),
            "reason": self.r(&f.reason),
            "allocatedBytes": f.allocated_bytes,
            "logicalBytes": f.logical_bytes,
            "partialMeasurement": f.partial_measurement,
            "sharedLinks": f.shared_links,
            "automaticAllowed": f.category.allows_automatic(),
            "details": f.details.iter().map(|d| self.r(d)).collect::<Vec<_>>(),
        });
        if let Some(w) = &f.worktree {
            let mut wv = json!({
                "status": w.status.raw(),
                "statusTitle": self.t(&format!("wtstatus.{}", w.status.raw())),
                "repository": w.repository,
                "pending": w.has_pending(),
            });
            let o = wv.as_object_mut().expect("object");
            if let Some(b) = &w.branch {
                o.insert("branch".into(), json!(b.strip_prefix("refs/heads/").unwrap_or(b)));
            }
            for (k, val) in [
                ("head", w.head.as_ref().map(|x| json!(x))),
                ("comparisonReference", w.comparison_reference.as_ref().map(|x| json!(x))),
                ("localChanges", w.local_changes.map(|x| json!(x))),
                ("unpublishedCommits", w.unpublished_commits.map(|x| json!(x))),
                ("unmergedCommits", w.unmerged_commits.map(|x| json!(x))),
                ("ignoredPaths", w.ignored_paths.map(|x| json!(x))),
            ] {
                if let Some(val) = val {
                    o.insert(k.into(), val);
                }
            }
            v.as_object_mut().expect("object").insert("worktree".into(), wv);
        }
        v
    }

    fn item_text(&self, f: &Finding) -> String {
        let size = if f.partial_measurement {
            format!("≥ {}", self.bytes(f.allocated_bytes))
        } else {
            self.bytes(f.allocated_bytes)
        };
        let mut s = format!(
            "[{}] {}  {}\n  {}\n  {}",
            self.t(&format!("state.{}", f.state.raw())),
            size,
            self.r(&f.title),
            f.path,
            self.r(&f.reason)
        );
        if let Some(w) = &f.worktree {
            s.push_str(&format!("\n  {}", self.t(&format!("wtstatus.{}", w.status.raw()))));
        }
        for d in &f.details {
            s.push_str(&format!("\n    · {}", self.r(d)));
        }
        s
    }

    pub fn scan(&self, scan: &ScanSnapshot, items: &[&Finding]) {
        let ready: Vec<&&Finding> = items.iter().filter(|f| f.state == FindingState::Ready).collect();
        let ready_bytes: u64 = ready.iter().map(|f| f.allocated_bytes).sum();
        if self.json {
            let mut counts = serde_json::Map::new();
            for s in [
                FindingState::Ready,
                FindingState::InUse,
                FindingState::Protected,
                FindingState::Review,
                FindingState::Inaccessible,
            ] {
                counts.insert(s.raw().into(), json!(items.iter().filter(|f| f.state == s).count()));
            }
            print_json(&json!({
                "schemaVersion": 1,
                "language": self.lang.code(),
                "scannedAt": rfc3339(scan.date),
                "mode": scan.mode,
                "items": items.iter().map(|f| self.summary(f)).collect::<Vec<_>>(),
                "counts": counts,
                "readyAllocatedBytes": ready_bytes,
                "notices": scan.notices.iter().map(|n| self.r(n)).collect::<Vec<_>>(),
            }));
            return;
        }
        let body: Vec<String> = items.iter().map(|f| self.item_text(f)).collect();
        println!("{}", body.join("\n\n"));
        println!(
            "\n{}",
            i18n::render(
                self.lang,
                &Msg::new("cli.scan_summary")
                    .arg(ready.len())
                    .arg(self.bytes(ready_bytes))
            )
        );
        println!(
            "\n{}",
            scan.notices
                .iter()
                .map(|n| format!("· {}", self.r(n)))
                .collect::<Vec<_>>()
                .join("\n")
        );
    }

    pub fn plan(&self, scanned_at: i64, file: Option<&Path>, findings: &[Finding]) {
        if self.json {
            let mut v = json!({
                "schemaVersion": 1,
                "language": self.lang.code(),
                "scannedAt": rfc3339(scanned_at),
                "expiresAt": rfc3339(scanned_at + PLAN_TTL_SECS),
                "items": findings.iter().map(|f| self.summary(f)).collect::<Vec<_>>(),
                "allocatedBytes": findings.iter().map(|f| f.allocated_bytes).sum::<u64>(),
            });
            if let Some(p) = file {
                v.as_object_mut()
                    .expect("object")
                    .insert("planFile".into(), json!(p.to_string_lossy()));
            }
            print_json(&v);
            return;
        }
        println!(
            "{}",
            findings
                .iter()
                .map(|f| self.item_text(f))
                .collect::<Vec<_>>()
                .join("\n\n")
        );
        match file {
            Some(p) => println!("\n{}", self.r(&Msg::new("cli.plan_saved").arg(p.display()))),
            None => println!("\n{}", self.t("cli.preview_only")),
        }
    }

    pub fn report(&self, report: &CleaningReport) {
        if self.json {
            print_json(&self.report_json(report));
            return;
        }
        for o in &report.outcomes {
            let tag = if o.removed {
                self.t("cli.tag_removed")
            } else if o.partially_removed {
                self.t("cli.tag_partial")
            } else {
                self.t("cli.tag_preserved")
            };
            println!("[{tag}] {}\n  {}", o.path, self.r(&o.message));
        }
        println!(
            "\n{}",
            self.r(&Msg::new("cli.estimated_freed").arg(self.bytes(report.removed_allocated())))
        );
        match report.net_change() {
            Some(n) => println!(
                "{}",
                self.r(&Msg::new("cli.free_space_change").arg(self.signed_bytes(n)))
            ),
            None => println!("{}", self.t("cli.free_space_unavailable")),
        }
    }

    fn signed_bytes(&self, n: i64) -> String {
        let s = self.bytes(n.unsigned_abs());
        if n < 0 {
            format!("−{s}")
        } else {
            format!("+{s}")
        }
    }

    fn report_json(&self, r: &CleaningReport) -> Value {
        json!({
            "date": rfc3339(r.date),
            "automatic": r.automatic,
            "outcomes": r.outcomes.iter().map(|o| json!({
                "path": o.path,
                "removed": o.removed,
                "partiallyRemoved": o.partially_removed,
                "message": self.r(&o.message),
                "allocatedBytes": o.allocated_bytes,
            })).collect::<Vec<_>>(),
            "estimatedFreedBytes": r.removed_allocated(),
            "availableBefore": r.available_before,
            "availableAfter": r.available_after,
            "netFreeSpaceChange": r.net_change(),
        })
    }

    pub fn history(&self, reports: &[CleaningReport]) {
        if self.json {
            print_json(&Value::Array(reports.iter().map(|r| self.report_json(r)).collect()));
            return;
        }
        if reports.is_empty() {
            println!("{}", self.t("cli.no_history"));
            return;
        }
        for r in reports {
            println!("{}", rfc3339(r.date));
            for o in &r.outcomes {
                println!("  {}: {}", o.path, self.r(&o.message));
            }
        }
    }

    pub fn categories(&self, catalog: &Catalog) {
        let rows: Vec<Value> = Category::ALL
            .iter()
            .map(|c| {
                let sources: Vec<String> = catalog
                    .rules
                    .iter()
                    .filter(|r| r.category == *c)
                    .map(|r| r.source.clone())
                    .collect();
                json!({
                    "id": c.cli_name(),
                    "title": self.t(&c.title_key()),
                    "automatic": c.allows_automatic(),
                    "inspectionOnly": c.inspection_only(),
                    "defaultEnabled": Category::default_enabled().contains(c),
                    "paths": sources,
                })
            })
            .collect();
        if self.json {
            print_json(&json!({ "categories": rows, "notOnLinux": NOT_ON_LINUX }));
            return;
        }
        for c in Category::ALL {
            let mut line = format!("{:<18}{}", c.cli_name(), self.t(&c.title_key()));
            if c.inspection_only() {
                line.push_str(&format!(" [{}]", self.t("cli.inspection_only_tag")));
            } else if !c.allows_automatic() {
                line.push_str(&format!(" [{}]", self.t("cli.manual_tag")));
            }
            println!("{line}");
        }
        println!(
            "\n{}",
            self.r(&Msg::new("cli.not_on_linux").arg(NOT_ON_LINUX.join(", ")))
        );
    }

    pub fn prefs(&self, p: &Preferences) {
        // Settings are always printed as JSON, like the original CLI.
        print_json(&json!({
            "enabledCategories": p.enabled_categories.iter().map(|c| c.cli_name()).collect::<Vec<_>>(),
            "exclusions": p.exclusions,
            "projectRoots": p.project_roots,
            "retentionDays": p.retention_days,
            "logRetentionDays": p.log_retention_days,
            "scheduleEnabled": p.schedule_enabled,
            "scheduleMode": p.schedule_mode,
            "intervalHours": p.interval_hours,
            "language": p.language,
        }));
    }

    pub fn status(&self, p: &Preferences, s: &PersistedState, reg: &Registration) {
        let scan = s.last_scan.as_ref();
        let ready: Vec<&Finding> = scan
            .map(|x| x.findings.iter().filter(|f| f.state == FindingState::Ready).collect())
            .unwrap_or_default();
        let bytes: u64 = ready.iter().map(|f| f.allocated_bytes).sum();
        if self.json {
            print_json(&json!({
                "version": sniff_core::VERSION,
                "language": self.lang.code(),
                "scanDate": scan.map(|x| rfc3339(x.date)),
                "findings": scan.map(|x| x.findings.len()).unwrap_or(0),
                "readyItems": ready.len(),
                "estimatedAllocatedBytes": bytes,
                "cleanupReports": s.history.len(),
                "scheduleEnabled": p.schedule_enabled,
                "scheduleRegistration": reg,
            }));
            return;
        }
        println!("Sniff {}", sniff_core::VERSION);
        println!(
            "{}",
            self.r(&Msg::new("cli.status_last_scan")
                .arg(scan.map(|x| rfc3339(x.date)).unwrap_or_else(|| self.t("cli.never"))))
        );
        println!(
            "{}",
            self.r(&Msg::new("cli.scan_summary").arg(ready.len()).arg(self.bytes(bytes)))
        );
        println!("{}", self.registration_line(p, reg));
    }

    fn registration_line(&self, p: &Preferences, reg: &Registration) -> String {
        let key = match (p.schedule_enabled, reg.enabled && reg.active) {
            (false, false) => "cli.schedule_off",
            (true, true) => "cli.schedule_on",
            _ => "cli.schedule_mismatch",
        };
        self.t(key)
    }

    pub fn schedule(&self, p: &Preferences, s: &PersistedState, reg: &Registration) {
        if self.json {
            print_json(&json!({
                "scheduleEnabled": p.schedule_enabled,
                "mode": p.schedule_mode,
                "intervalHours": p.interval_hours,
                "registration": reg,
                "nextRun": s.next_run.map(rfc3339),
                "lastWake": s.scheduler_last_wake.map(rfc3339),
                "message": s.scheduler_message.as_ref().map(|m| self.r(m)),
            }));
            return;
        }
        println!("{}", self.registration_line(p, reg));
        if let Some(n) = &reg.next_elapse {
            println!("{}", self.r(&Msg::new("cli.schedule_next").arg(n)));
        }
        if let Some(m) = &s.scheduler_message {
            println!("{}", self.r(m));
        }
    }

    pub fn strings(&self) {
        print_json(&json!({ "language": self.lang.code(), "strings": i18n::ui_strings(self.lang) }));
    }
}

/// Plan review printed to stderr before the confirmation prompt.
pub fn print_plan_review(lang: Lang, findings: &[Finding]) {
    eprintln!("{}", i18n::text(lang, "cli.review_header"));
    for f in findings {
        eprintln!("  {}  {}", i18n::format_bytes(lang, f.allocated_bytes), f.path);
        if f.category == Category::Worktree {
            eprintln!("    {}", i18n::text(lang, "detail.no_backup"));
        }
    }
    let total: u64 = findings.iter().map(|f| f.allocated_bytes).sum();
    eprintln!(
        "{}",
        i18n::render(
            lang,
            &Msg::new("cli.review_total")
                .arg(findings.len())
                .arg(i18n::format_bytes(lang, total))
        )
    );
}

pub fn help(lang: Lang) -> String {
    let t = |k: &str| i18n::text(lang, k);
    let rows: &[(&str, &str)] = &[
        ("scan [--quick | --worktrees]", "help.scan"),
        ("list [--ready] [--filter <f>] [--search <t>]", "help.list"),
        ("plan [--category <name> | --path <p>]", "help.plan"),
        ("     [--output <new-file> | --save]", "help.plan_output"),
        ("clean --plan <file> [--yes]", "help.clean"),
        ("status", "help.status"),
        ("history", "help.history"),
        ("categories", "help.categories"),
        ("config --enable|--disable <name>", "help.config"),
        ("       --project|--exclude <path>", "help.config_paths"),
        ("       --retention-days <n>", "help.config_retention"),
        ("schedule [status|enable|disable]", "help.schedule"),
    ];
    let opts: &[(&str, &str)] = &[
        ("--json", "help.json"),
        ("--language en|pt|es|system", "help.language"),
        ("--help, -h", "help.help"),
        ("--version, -v", "help.version"),
    ];
    let mut s = format!(
        "sniff {}\n{}\n\n{}\n  sniff <command> [options]\n\n{}\n",
        sniff_core::VERSION,
        t("help.tagline"),
        t("help.usage"),
        t("help.commands")
    );
    for (a, k) in rows {
        s.push_str(&format!("  {a:<46}{}\n", t(k)));
    }
    s.push_str(&format!("\n{}\n", t("help.options")));
    for (a, k) in opts {
        s.push_str(&format!("  {a:<46}{}\n", t(k)));
    }
    s.push_str(&format!("\n{}\n{}", t("help.expiry"), t("help.manual")));
    s
}
