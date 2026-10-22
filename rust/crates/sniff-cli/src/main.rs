//! `sniff` command line. Shares the core with the Omarchy plugin, which calls
//! this binary with `--json`.

mod args;
mod output;

use args::{Action, Request};
use output::Out;
use sniff_core::catalog::{Catalog, ToolEnv};
use sniff_core::executor::{apply_report, default_use_check, Executor};
use sniff_core::i18n::{self, Lang};
use sniff_core::model::*;
use sniff_core::paths::{canonical, expand_tilde, to_string};
use sniff_core::plan::{self, Failure, PlanDocument};
use sniff_core::procs::ProcessInventory;
use sniff_core::scanner::Scanner;
use sniff_core::schedule::{self, UnitSpec};
use sniff_core::store::{self, Dirs, OperationLock, StoreError};
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

struct Ctx {
    dirs: Dirs,
    catalog: Catalog,
    lang: Lang,
    out: Out,
}

fn store_failure(e: StoreError) -> Failure {
    match e {
        StoreError::Busy => Failure::runtime(Msg::new("cli.busy")),
        StoreError::Corrupt(p, _) => Failure::runtime(Msg::new("cli.state_corrupt").arg(p.display())),
        StoreError::Insecure(p) => Failure::runtime(Msg::new("cli.state_insecure").arg(p.display())),
        StoreError::Io(p, e) => Failure::runtime(Msg::new("reason.io_error").arg(format!("{}: {e}", p.display()))),
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let json = argv.iter().any(|a| a == "--json");
    let lang_arg = argv
        .iter()
        .position(|a| a == "--language")
        .and_then(|i| argv.get(i + 1))
        .and_then(|l| Lang::parse_choice(l));
    let fallback_lang = lang_arg.unwrap_or_else(|| Lang::resolve("system", None));
    let req = match args::parse(&argv) {
        Ok(r) => r,
        Err(f) => return fail(f, json, fallback_lang),
    };
    let Some(dirs) = Dirs::from_env() else {
        return fail(Failure::runtime(Msg::new("cli.no_home")), json, fallback_lang);
    };
    let prefs_lang = store::load_prefs(&dirs)
        .map(|p| p.language)
        .unwrap_or_else(|_| "system".into());
    let lang = Lang::resolve(&prefs_lang, req.language.as_deref());
    let fixture_home = std::env::var_os("SNIFF_HOME").is_some();
    let env = if fixture_home {
        ToolEnv::empty()
    } else {
        ToolEnv::from_process()
    };
    let mut catalog = Catalog::new(&dirs.home, &env);
    if fixture_home {
        // Tools running on this machine use the real home, never the fixture
        // home, so their command lines say nothing about fixture caches. Open
        // files, working directories and command lines naming fixture paths
        // are still checked.
        for rule in &mut catalog.rules {
            rule.tokens = &[];
        }
    }
    let mut ctx = Ctx {
        dirs,
        catalog,
        lang,
        out: Out { json: req.json, lang },
    };
    match run(&mut ctx, &req) {
        Ok(code) => ExitCode::from(code),
        Err(f) => fail(f, req.json, lang),
    }
}

fn fail(f: Failure, json: bool, lang: Lang) -> ExitCode {
    let text = i18n::render(lang, &f.msg);
    if json {
        println!(
            "{}",
            serde_json::json!({ "error": text, "errorKey": f.msg.k, "exitCode": f.code })
        );
    } else {
        eprintln!("sniff: {text}");
    }
    ExitCode::from(f.code as u8)
}

fn run(ctx: &mut Ctx, req: &Request) -> Result<u8, Failure> {
    match req.action {
        Action::Help => {
            println!("{}", output::help(ctx.lang));
            Ok(0)
        }
        Action::Version => {
            println!("{}", sniff_core::VERSION);
            Ok(0)
        }
        Action::Categories => {
            ctx.out.categories(&ctx.catalog);
            Ok(0)
        }
        Action::Strings => {
            ctx.out.strings();
            Ok(0)
        }
        Action::Status => cmd_status(ctx),
        Action::Scan => cmd_scan(ctx, req),
        Action::List => cmd_list(ctx, req),
        Action::Plan => cmd_plan(ctx, req),
        Action::Clean => cmd_clean(ctx, req),
        Action::History => {
            let state = store::load_state(&ctx.dirs).map_err(store_failure)?;
            ctx.out.history(&state.history);
            Ok(0)
        }
        Action::Config => cmd_config(ctx, req),
        Action::Schedule => cmd_schedule(ctx, req),
        Action::ScheduledRun => cmd_scheduled_run(ctx, req),
    }
}

fn cmd_status(ctx: &Ctx) -> Result<u8, Failure> {
    let prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
    let state = store::load_state(&ctx.dirs).map_err(store_failure)?;
    let reg = schedule::status(&UnitSpec::production(&ctx.dirs.home, current_exe()));
    ctx.out.status(&prefs, &state, &reg);
    Ok(0)
}

fn current_exe() -> PathBuf {
    std::env::current_exe()
        .map(|p| canonical(&p))
        .unwrap_or_else(|_| PathBuf::from("sniff"))
}

fn cmd_scan(ctx: &mut Ctx, req: &Request) -> Result<u8, Failure> {
    let _lock = OperationLock::acquire(&ctx.dirs, false).map_err(store_failure)?;
    let prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
    let mut state = store::load_state(&ctx.dirs).map_err(store_failure)?;
    let mode = if req.quick {
        ScanMode::Quick
    } else if req.worktrees {
        ScanMode::Worktrees
    } else {
        ScanMode::Full
    };
    let lang = ctx.lang;
    let quiet = req.json && !req.progress;
    let progress = move |m: Msg| {
        if quiet {
            return;
        }
        if req.json {
            // Machine-readable progress for the plugin: one line per step.
            eprintln!("{}", serde_json::json!({ "progress": i18n::render(lang, &m) }));
        } else {
            eprintln!("{}", i18n::render(lang, &m));
        }
    };
    let inventory = ProcessInventory::capture();
    let scanner = Scanner::new(&ctx.catalog, &prefs, &inventory, &progress);
    let scan = scanner.scan(mode);
    ctx.out.scan(&scan, &scan.findings.iter().collect::<Vec<_>>());
    state.last_scan = Some(scan);
    store::save_state(&ctx.dirs, &state).map_err(store_failure)?;
    Ok(0)
}

fn filtered<'a>(scan: &'a ScanSnapshot, req: &Request, home: &Path) -> Result<Vec<&'a Finding>, Failure> {
    let wanted: Vec<String> = req
        .paths
        .iter()
        .map(|p| to_string(&canonical(&expand_tilde(p, home))))
        .collect();
    let search = req.search.as_ref().map(|s| s.to_lowercase());
    let items = scan
        .findings
        .iter()
        .filter(|f| req.categories.is_empty() || req.categories.contains(&f.category))
        .filter(|f| wanted.is_empty() || wanted.contains(&f.path))
        .filter(|f| !req.ready || f.state == FindingState::Ready)
        .filter(|f| match req.filter.as_deref() {
            None | Some("all") => true,
            Some("ready") => f.state == FindingState::Ready,
            Some("pending") => f.worktree.as_ref().is_some_and(|w| w.has_pending()),
            Some("in-use") => f.state == FindingState::InUse,
            Some("preserved") => matches!(
                f.state,
                FindingState::Protected | FindingState::Review | FindingState::Inaccessible
            ),
            Some(_) => false,
        })
        .filter(|f| {
            search.as_ref().is_none_or(|s| {
                f.path.to_lowercase().contains(s)
                    || f.worktree
                        .as_ref()
                        .and_then(|w| w.branch.as_ref())
                        .is_some_and(|b| b.to_lowercase().contains(s))
            })
        })
        .collect();
    Ok(items)
}

fn cmd_list(ctx: &Ctx, req: &Request) -> Result<u8, Failure> {
    let state = store::load_state(&ctx.dirs).map_err(store_failure)?;
    let scan = state
        .last_scan
        .as_ref()
        .ok_or_else(|| Failure::usage(Msg::new("cli.no_scan")))?;
    let items = filtered(scan, req, &ctx.catalog.home)?;
    ctx.out.scan(scan, &items);
    Ok(0)
}

fn cmd_plan(ctx: &Ctx, req: &Request) -> Result<u8, Failure> {
    let prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
    let state = store::load_state(&ctx.dirs).map_err(store_failure)?;
    let now = store::now_secs();
    let findings = plan::select(
        state.last_scan.as_ref(),
        &prefs,
        &req.categories,
        &req.paths,
        &ctx.catalog.home,
        now,
    )?;
    let scanned_at = state.last_scan.as_ref().map(|s| s.date).unwrap_or(now);
    let output = match (&req.output, req.save) {
        (Some(o), _) => Some(expand_tilde(o, &ctx.dirs.home)),
        (None, true) => {
            let dir = ctx.dirs.state.join("plans");
            store::ensure_private_dir(&dir).map_err(store_failure)?;
            Some(dir.join(format!("plan-{now}-{}.json", std::process::id())))
        }
        (None, false) => None,
    };
    if let Some(path) = &output {
        let _lock = OperationLock::acquire(&ctx.dirs, false).map_err(store_failure)?;
        let doc = PlanDocument {
            schema_version: 1,
            home: to_string(&ctx.catalog.home),
            scanned_at,
            created_at: now,
            findings: findings.clone(),
        };
        plan::write_plan(path, &doc)?;
    }
    ctx.out.plan(scanned_at, output.as_deref(), &findings);
    Ok(0)
}

fn cmd_clean(ctx: &Ctx, req: &Request) -> Result<u8, Failure> {
    let plan_path = expand_tilde(req.plan.as_deref().unwrap_or_default(), &ctx.dirs.home);
    let doc = plan::read_plan(&plan_path, &ctx.catalog.home, store::now_secs())?;
    output::print_plan_review(ctx.lang, &doc.findings);
    if !req.yes {
        if !std::io::stdin().is_terminal() {
            return Err(Failure {
                msg: Msg::new("cli.noninteractive_needs_yes"),
                code: 3,
            });
        }
        eprint!("{}", i18n::text(ctx.lang, "cli.type_clean"));
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        let _ = std::io::stdin().lock().read_line(&mut line);
        if line.trim_end_matches(['\n', '\r']) != "CLEAN" {
            println!("{}", i18n::text(ctx.lang, "cli.cancelled"));
            return Ok(3);
        }
    }
    let _lock = OperationLock::acquire(&ctx.dirs, false).map_err(store_failure)?;
    let prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
    let mut state = store::load_state(&ctx.dirs).map_err(store_failure)?;
    let mut use_check = default_use_check(&ctx.catalog);
    let mut hook = |_: &str| {};
    let clock = store::now_secs;
    let mut ex = Executor {
        catalog: &ctx.catalog,
        prefs: &prefs,
        automatic: false,
        use_check: &mut use_check,
        before_unlink: &mut hook,
        now: &clock,
    };
    let report = ex.execute(&doc.findings, doc.scanned_at);
    apply_report(&mut state, &report);
    store::save_state(&ctx.dirs, &state).map_err(store_failure)?;
    ctx.out.report(&report);
    Ok(if report.all_removed() { 0 } else { 4 })
}

fn cmd_config(ctx: &Ctx, req: &Request) -> Result<u8, Failure> {
    let changes = !(req.enable.is_empty()
        && req.disable.is_empty()
        && req.projects.is_empty()
        && req.remove_projects.is_empty()
        && req.excludes.is_empty()
        && req.remove_excludes.is_empty()
        && req.retention_days.is_none()
        && req.log_retention_days.is_none()
        && req.set_language.is_none());
    // Reading settings does not need the lock, so the panel can show them
    // while a scan runs.
    let _lock = if changes {
        Some(OperationLock::acquire(&ctx.dirs, false).map_err(store_failure)?)
    } else {
        None
    };
    let mut prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
    let before = prefs.clone();
    for c in &req.enable {
        if c.inspection_only() {
            return Err(Failure::usage(Msg::new("cli.inspection_only").arg(c.cli_name())));
        }
        prefs.enabled_categories.insert(*c);
    }
    for c in &req.disable {
        prefs.enabled_categories.remove(c);
    }
    for p in &req.projects {
        let path = canonical(&expand_tilde(p, &ctx.dirs.home));
        if !path.is_dir() || path == Path::new("/") {
            return Err(Failure::usage(Msg::new("cli.choose_project").arg(p)));
        }
        let s = to_string(&path);
        if !prefs.project_roots.contains(&s) {
            prefs.project_roots.push(s);
        }
    }
    for p in &req.remove_projects {
        let s = to_string(&canonical(&expand_tilde(p, &ctx.dirs.home)));
        prefs.project_roots.retain(|r| r != &s && r != p);
    }
    for p in &req.excludes {
        let s = to_string(&canonical(&expand_tilde(p, &ctx.dirs.home)));
        if !prefs.exclusions.contains(&s) {
            prefs.exclusions.push(s);
        }
    }
    for p in &req.remove_excludes {
        let s = to_string(&canonical(&expand_tilde(p, &ctx.dirs.home)));
        prefs.exclusions.retain(|r| r != &s && r != p);
    }
    if let Some(d) = req.retention_days {
        prefs.retention_days = d.clamp(1, 3650);
    }
    if let Some(d) = req.log_retention_days {
        prefs.log_retention_days = d.clamp(1, 3650);
    }
    if let Some(l) = &req.set_language {
        prefs.language = l.clone();
    }
    if prefs != before {
        store::save_prefs(&ctx.dirs, &prefs).map_err(store_failure)?;
    }
    ctx.out.prefs(&prefs);
    Ok(0)
}

fn unit_spec(ctx: &Ctx, req: &Request) -> UnitSpec {
    let mut spec = UnitSpec::production(&ctx.dirs.home, current_exe());
    if let Some(name) = &req.unit_name {
        spec.name = name.clone();
    }
    if req.fixture {
        spec.args.push("--fixture".into());
        spec.fixture_delay = Some(3);
        if let Some(h) = std::env::var_os("SNIFF_HOME") {
            spec.env.push(("SNIFF_HOME".into(), h.to_string_lossy().into_owned()));
        }
    }
    spec
}

fn cmd_schedule(ctx: &Ctx, req: &Request) -> Result<u8, Failure> {
    let spec = unit_spec(ctx, req);
    let sub = req.sub.as_deref().unwrap_or("status");
    if sub == "status" {
        let prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
        let state = store::load_state(&ctx.dirs).map_err(store_failure)?;
        ctx.out.schedule(&prefs, &state, &schedule::status(&spec));
        return Ok(0);
    }
    let _lock = OperationLock::acquire(&ctx.dirs, false).map_err(store_failure)?;
    let mut prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
    let reg = match sub {
        "enable" => {
            if let Some(m) = req.mode {
                prefs.schedule_mode = m;
            }
            if let Some(h) = req.interval_hours {
                prefs.interval_hours = h.clamp(1, 168);
            }
            let reg = schedule::enable(&spec).map_err(Failure::runtime)?;
            prefs.schedule_enabled = true;
            reg
        }
        "disable" => {
            let reg = schedule::disable(&spec).map_err(Failure::runtime)?;
            prefs.schedule_enabled = false;
            reg
        }
        _ => return Err(Failure::usage(Msg::new("cli.unknown").arg(sub))),
    };
    store::save_prefs(&ctx.dirs, &prefs).map_err(store_failure)?;
    let state = store::load_state(&ctx.dirs).map_err(store_failure)?;
    ctx.out.schedule(&prefs, &state, &reg);
    Ok(0)
}

fn cmd_scheduled_run(ctx: &Ctx, req: &Request) -> Result<u8, Failure> {
    let _lock = OperationLock::acquire(&ctx.dirs, true).map_err(store_failure)?;
    let prefs = store::load_prefs(&ctx.dirs).map_err(store_failure)?;
    let mut state = store::load_state(&ctx.dirs).map_err(store_failure)?;
    schedule::run_once(&ctx.catalog, &prefs, &mut state, store::now_secs(), req.fixture);
    store::save_state(&ctx.dirs, &state).map_err(store_failure)?;
    if let Some(m) = &state.scheduler_message {
        eprintln!("{}", i18n::render(ctx.lang, m));
    }
    Ok(0)
}
