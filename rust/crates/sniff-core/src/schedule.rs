//! Scheduling through a systemd user timer.
//!
//! Registration writes two unit files under `~/.config/systemd/user/`, then
//! asks the user manager to reload and enable the timer. The timer wakes
//! every 15 minutes; the run itself decides whether it is due. The service
//! runs at the lowest CPU and I/O priority and never asks for privileges.
//! Status is read back from systemd, so a saved preference alone never
//! claims that scheduling works.

use crate::catalog::{Catalog, BUILD_IN_PROGRESS};
use crate::executor::{apply_report, default_use_check, Executor};
use crate::model::*;
use crate::procs::ProcessInventory;
use crate::scanner::Scanner;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const DEFAULT_UNIT: &str = "sniff-scheduler";
pub const DEFER_SECS: i64 = 3600;
const MARKER: &str = "# Managed by Sniff. Remove with: sniff schedule disable";

pub struct UnitSpec {
    pub name: String,
    pub unit_dir: PathBuf,
    pub exec: PathBuf,
    /// Extra arguments after `scheduled-run`.
    pub args: Vec<String>,
    /// Extra environment for the service (fixtures).
    pub env: Vec<(String, String)>,
    pub on_calendar: String,
    pub fixture_delay: Option<u32>,
}

impl UnitSpec {
    /// Units always go to the real user's systemd directory, even when a
    /// fixture home is used for Sniff's own state.
    pub fn production(home: &Path, exec: PathBuf) -> Self {
        let real_home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home.to_path_buf());
        UnitSpec {
            name: DEFAULT_UNIT.into(),
            unit_dir: user_unit_dir(&real_home),
            exec,
            args: Vec::new(),
            env: Vec::new(),
            on_calendar: "*:0/15".into(),
            fixture_delay: None,
        }
    }

    pub fn service_text(&self) -> String {
        let mut exec = vec![systemd_quote(&self.exec.to_string_lossy()), "scheduled-run".to_string()];
        exec.extend(self.args.iter().map(|a| systemd_quote(a)));
        let env: String = self
            .env
            .iter()
            .map(|(k, v)| format!("Environment={}\n", systemd_quote(&format!("{k}={v}"))))
            .collect();
        format!(
            "{MARKER}\n[Unit]\nDescription=Sniff scheduled cache maintenance\nDocumentation=https://github.com/JohnRenatoDev/sniff-cleaner\n\n\
[Service]\nType=oneshot\nExecStart={}\n{env}Nice=19\nIOSchedulingClass=idle\nCPUSchedulingPolicy=idle\nNoNewPrivileges=yes\nTimeoutStartSec=30min\n",
            exec.join(" ")
        )
    }

    pub fn timer_text(&self) -> String {
        let when = match self.fixture_delay {
            Some(s) => format!("OnActiveSec={s}s\nAccuracySec=1s\n"),
            None => format!(
                "OnCalendar={}\nPersistent=true\nRandomizedDelaySec=60\nAccuracySec=1min\n",
                self.on_calendar
            ),
        };
        format!("{MARKER}\n[Unit]\nDescription=Sniff scheduled cache maintenance timer\n\n[Timer]\n{when}Unit={}.service\n\n[Install]\nWantedBy=timers.target\n", self.name)
    }

    pub fn service_path(&self) -> PathBuf {
        self.unit_dir.join(format!("{}.service", self.name))
    }
    pub fn timer_path(&self) -> PathBuf {
        self.unit_dir.join(format!("{}.timer", self.name))
    }
}

pub fn user_unit_dir(home: &Path) -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".config"))
        .join("systemd/user")
}

fn systemd_quote(s: &str) -> String {
    let escaped = s
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%")
        .replace('$', "$$");
    format!("\"{escaped}\"")
}

fn systemctl(args: &[&str]) -> crate::command::Output {
    let mut argv = vec!["--user"];
    argv.extend_from_slice(args);
    crate::command::run(Path::new("/usr/bin/systemctl"), &argv, None, Duration::from_secs(20))
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Registration {
    pub unit_files_present: bool,
    pub enabled: bool,
    pub active: bool,
    pub next_elapse: Option<String>,
    pub last_trigger: Option<String>,
}

pub fn status(spec: &UnitSpec) -> Registration {
    let timer = format!("{}.timer", spec.name);
    let show = systemctl(&[
        "show",
        &timer,
        "--property=UnitFileState,ActiveState,NextElapseUSecRealtime,LastTriggerUSec",
    ]);
    let mut r = Registration {
        unit_files_present: spec.service_path().exists() && spec.timer_path().exists(),
        enabled: false,
        active: false,
        next_elapse: None,
        last_trigger: None,
    };
    for l in show.text().lines() {
        if let Some((k, v)) = l.split_once('=') {
            let v = v.trim();
            match k {
                "UnitFileState" => r.enabled = v == "enabled",
                "ActiveState" => r.active = v == "active",
                "NextElapseUSecRealtime" if !v.is_empty() && v != "n/a" => r.next_elapse = Some(v.to_string()),
                "LastTriggerUSec" if !v.is_empty() && v != "n/a" => r.last_trigger = Some(v.to_string()),
                _ => {}
            }
        }
    }
    r
}

pub fn enable(spec: &UnitSpec) -> Result<Registration, Msg> {
    for p in [spec.service_path(), spec.timer_path()] {
        if let Ok(text) = std::fs::read_to_string(&p) {
            if !text.starts_with(MARKER) {
                return Err(Msg::new("schedule.foreign_unit").arg(p.display()));
            }
        }
    }
    std::fs::create_dir_all(&spec.unit_dir).map_err(|e| Msg::new("reason.io_error").arg(e))?;
    crate::store::write_atomic(&spec.service_path(), spec.service_text().as_bytes())
        .map_err(|e| Msg::new("reason.io_error").arg(e))?;
    crate::store::write_atomic(&spec.timer_path(), spec.timer_text().as_bytes())
        .map_err(|e| Msg::new("reason.io_error").arg(e))?;
    if !systemctl(&["daemon-reload"]).ok() {
        return Err(Msg::new("schedule.systemctl_failed"));
    }
    let timer = format!("{}.timer", spec.name);
    if !systemctl(&["enable", "--now", &timer]).ok() {
        return Err(Msg::new("schedule.systemctl_failed"));
    }
    Ok(status(spec))
}

pub fn disable(spec: &UnitSpec) -> Result<Registration, Msg> {
    let timer = format!("{}.timer", spec.name);
    let _ = systemctl(&["disable", "--now", &timer]);
    for p in [spec.timer_path(), spec.service_path()] {
        match std::fs::read_to_string(&p) {
            Ok(text) if text.starts_with(MARKER) => {
                std::fs::remove_file(&p).map_err(|e| Msg::new("reason.io_error").arg(e))?;
            }
            Ok(_) => return Err(Msg::new("schedule.foreign_unit").arg(p.display())),
            Err(_) => {}
        }
    }
    let _ = systemctl(&["daemon-reload"]);
    Ok(status(spec))
}

pub fn is_due(prefs: &Preferences, state: &PersistedState, now: i64) -> bool {
    prefs.schedule_enabled && state.next_run.is_none_or(|t| t <= now)
}

/// One scheduled wake. In fixture mode nothing is scanned or removed; the
/// wake is only recorded so registration and wake-up can be tested.
pub fn run_once(catalog: &Catalog, prefs: &Preferences, state: &mut PersistedState, now: i64, fixture: bool) {
    state.scheduler_last_wake = Some(now);
    if fixture {
        state.scheduler_message = Some(Msg::new("schedule.fixture_run"));
        return;
    }
    if !is_due(prefs, state, now) {
        if !prefs.schedule_enabled {
            state.scheduler_message = Some(Msg::new("schedule.disabled"));
        }
        return;
    }
    let inventory = ProcessInventory::capture();
    if !inventory.is_complete() || inventory.build_in_progress(BUILD_IN_PROGRESS) {
        state.scheduler_message = Some(Msg::new("schedule.deferred"));
        state.next_run = Some(now + DEFER_SECS);
        return;
    }
    let progress = |_m: Msg| {};
    let scanner = Scanner::new(catalog, prefs, &inventory, &progress);
    let scan = scanner.scan(ScanMode::Quick);
    let ready = scan.findings.iter().filter(|f| f.state == FindingState::Ready).count();
    match prefs.schedule_mode {
        ScheduleMode::Analyze => {
            state.scheduler_message = Some(Msg::new("schedule.analyzed").arg(ready));
            state.last_scan = Some(scan);
        }
        ScheduleMode::Automatic => {
            let plan: Vec<Finding> = scan
                .findings
                .iter()
                .filter(|f| {
                    f.state == FindingState::Ready
                        && f.category.allows_automatic()
                        && prefs.enabled_categories.contains(&f.category)
                })
                .cloned()
                .collect();
            let date = scan.date;
            state.last_scan = Some(scan);
            if !plan.is_empty() {
                let mut use_check = default_use_check(catalog);
                let mut hook = |_: &str| {};
                let clock = crate::store::now_secs;
                let mut ex = Executor {
                    catalog,
                    prefs,
                    automatic: true,
                    use_check: &mut use_check,
                    before_unlink: &mut hook,
                    now: &clock,
                };
                let report = ex.execute(&plan, date);
                let removed = report.outcomes.iter().filter(|o| o.removed).count();
                apply_report(state, &report);
                state.scheduler_message = Some(Msg::new("schedule.cleaned").arg(removed));
            } else {
                state.scheduler_message = Some(Msg::new("schedule.cleaned").arg(0));
            }
        }
    }
    state.next_run = Some(now + i64::from(prefs.interval_hours.clamp(1, 168)) * 3600);
}
