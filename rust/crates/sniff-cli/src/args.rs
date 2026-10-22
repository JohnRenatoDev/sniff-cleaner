//! Argument parsing. Hand-written to keep the binary small and the rules
//! identical to the original CLI: one action word, options validated per
//! action, usage errors exit with status 2.

use sniff_core::i18n::Lang;
use sniff_core::model::{Category, Msg, ScheduleMode, NOT_ON_LINUX};
use sniff_core::plan::Failure;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Action {
    #[default]
    Help,
    Version,
    Status,
    Scan,
    List,
    Categories,
    Plan,
    Clean,
    History,
    Config,
    Schedule,
    ScheduledRun,
    Strings,
}

#[derive(Debug, Default)]
pub struct Request {
    pub action: Action,
    pub sub: Option<String>,
    pub json: bool,
    pub progress: bool,
    pub quick: bool,
    pub worktrees: bool,
    pub yes: bool,
    pub ready: bool,
    pub save: bool,
    pub fixture: bool,
    pub output: Option<String>,
    pub plan: Option<String>,
    pub language: Option<String>,
    pub categories: Vec<Category>,
    pub paths: Vec<String>,
    pub filter: Option<String>,
    pub search: Option<String>,
    pub enable: Vec<Category>,
    pub disable: Vec<Category>,
    pub projects: Vec<String>,
    pub remove_projects: Vec<String>,
    pub excludes: Vec<String>,
    pub remove_excludes: Vec<String>,
    pub retention_days: Option<u32>,
    pub log_retention_days: Option<u32>,
    pub set_language: Option<String>,
    pub mode: Option<ScheduleMode>,
    pub interval_hours: Option<u32>,
    pub unit_name: Option<String>,
}

fn usage(k: &str) -> Failure {
    Failure::usage(Msg::new(k))
}

fn category(v: &str) -> Result<Category, Failure> {
    if NOT_ON_LINUX.contains(&v.to_ascii_lowercase().as_str()) {
        return Err(Failure::usage(Msg::new("cli.category_not_on_linux").arg(v)));
    }
    Category::parse(v).ok_or_else(|| Failure::usage(Msg::new("cli.unknown_category").arg(v)))
}

pub fn parse(argv: &[String]) -> Result<Request, Failure> {
    let mut r = Request::default();
    let mut action: Option<Action> = None;
    let mut help = false;
    let mut version = false;
    let mut i = 0;
    let mut seen_filter_opts = false;
    let mut seen_config_opts = false;
    let value = |i: &mut usize, name: &str| -> Result<String, Failure> {
        *i += 1;
        match argv.get(*i) {
            Some(v) if !v.starts_with("--") => Ok(v.clone()),
            _ => Err(Failure::usage(Msg::new("cli.missing_value").arg(name))),
        }
    };
    while i < argv.len() {
        let a = argv[i].as_str();
        match a {
            "--help" | "-h" => help = true,
            "--version" | "-v" => version = true,
            "--json" => r.json = true,
            "--progress" => r.progress = true,
            "--quick" => r.quick = true,
            "--worktrees" => r.worktrees = true,
            "--yes" | "-y" => r.yes = true,
            "--ready" => r.ready = true,
            "--save" => r.save = true,
            "--fixture" => r.fixture = true,
            "--output" | "-o" => r.output = Some(value(&mut i, a)?),
            "--plan" => r.plan = Some(value(&mut i, a)?),
            "--language" => {
                let v = value(&mut i, a)?;
                if Lang::parse_choice(&v).is_none() && v != "system" {
                    return Err(usage("cli.bad_language"));
                }
                r.language = Some(v);
            }
            "--category" => {
                r.categories.push(category(&value(&mut i, a)?)?);
                seen_filter_opts = true;
            }
            "--path" => {
                r.paths.push(value(&mut i, a)?);
                seen_filter_opts = true;
            }
            "--filter" => {
                let v = value(&mut i, a)?;
                if !["all", "ready", "pending", "in-use", "preserved"].contains(&v.as_str()) {
                    return Err(Failure::usage(Msg::new("cli.unknown").arg(v)));
                }
                r.filter = Some(v);
            }
            "--search" => r.search = Some(value(&mut i, a)?),
            "--enable" => {
                r.enable.push(category(&value(&mut i, a)?)?);
                seen_config_opts = true;
            }
            "--disable" => {
                r.disable.push(category(&value(&mut i, a)?)?);
                seen_config_opts = true;
            }
            "--project" => {
                r.projects.push(value(&mut i, a)?);
                seen_config_opts = true;
            }
            "--remove-project" => {
                r.remove_projects.push(value(&mut i, a)?);
                seen_config_opts = true;
            }
            "--exclude" => {
                r.excludes.push(value(&mut i, a)?);
                seen_config_opts = true;
            }
            "--remove-exclusion" => {
                r.remove_excludes.push(value(&mut i, a)?);
                seen_config_opts = true;
            }
            "--retention-days" | "--log-retention-days" | "--interval-hours" => {
                let v = value(&mut i, a)?;
                let n: u32 = v.parse().map_err(|_| Failure::usage(Msg::new("cli.unknown").arg(&v)))?;
                match a {
                    "--retention-days" => {
                        r.retention_days = Some(n);
                        seen_config_opts = true;
                    }
                    "--log-retention-days" => {
                        r.log_retention_days = Some(n);
                        seen_config_opts = true;
                    }
                    _ => r.interval_hours = Some(n),
                }
            }
            "--set-language" => {
                let v = value(&mut i, a)?;
                if Lang::parse_choice(&v).is_none() && v != "system" {
                    return Err(usage("cli.bad_language"));
                }
                r.set_language = Some(v);
                seen_config_opts = true;
            }
            "--mode" => {
                r.mode = Some(match value(&mut i, a)?.as_str() {
                    "analyze" => ScheduleMode::Analyze,
                    "automatic" => ScheduleMode::Automatic,
                    other => return Err(Failure::usage(Msg::new("cli.unknown").arg(other))),
                })
            }
            "--unit-name" => {
                let v = value(&mut i, a)?;
                if !v.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') || v.is_empty() {
                    return Err(Failure::usage(Msg::new("cli.unknown").arg(&v)));
                }
                r.unit_name = Some(v);
            }
            word if !word.starts_with('-') => {
                if action == Some(Action::Schedule) && r.sub.is_none() {
                    r.sub = Some(word.to_string());
                } else {
                    let act = match word {
                        "help" => Action::Help,
                        "version" => Action::Version,
                        "status" => Action::Status,
                        "scan" => Action::Scan,
                        "list" => Action::List,
                        "categories" => Action::Categories,
                        "plan" => Action::Plan,
                        "clean" => Action::Clean,
                        "history" => Action::History,
                        "config" => Action::Config,
                        "schedule" => Action::Schedule,
                        "scheduled-run" => Action::ScheduledRun,
                        "strings" => Action::Strings,
                        _ => return Err(Failure::usage(Msg::new("cli.unknown").arg(word))),
                    };
                    if action.is_some() {
                        return Err(Failure::usage(Msg::new("cli.unknown").arg(word)));
                    }
                    action = Some(act);
                }
            }
            other => return Err(Failure::usage(Msg::new("cli.unknown").arg(other))),
        }
        i += 1;
    }
    r.action = if help {
        Action::Help
    } else if version {
        Action::Version
    } else {
        action.unwrap_or(Action::Help)
    };
    validate(&r, seen_filter_opts, seen_config_opts)?;
    Ok(r)
}

fn validate(r: &Request, filters: bool, config: bool) -> Result<(), Failure> {
    use Action::*;
    let only = |cond: bool, allowed: &[Action], opt: &str| -> Result<(), Failure> {
        if cond && !allowed.contains(&r.action) && !matches!(r.action, Help | Version) {
            return Err(Failure::usage(
                Msg::new("cli.option_only_for").arg(opt).arg(
                    allowed
                        .iter()
                        .map(|a| format!("{a:?}").to_lowercase())
                        .collect::<Vec<_>>()
                        .join(", "),
                ),
            ));
        }
        Ok(())
    };
    if !r.categories.is_empty() && !r.paths.is_empty() {
        return Err(usage("cli.category_or_path"));
    }
    if r.quick && r.worktrees {
        return Err(usage("cli.quick_or_worktrees"));
    }
    only(r.quick, &[Scan], "--quick")?;
    only(r.worktrees, &[Scan], "--worktrees")?;
    only(r.progress, &[Scan], "--progress")?;
    only(r.yes, &[Clean], "--yes")?;
    only(r.ready, &[List], "--ready")?;
    only(r.filter.is_some(), &[List], "--filter")?;
    only(r.search.is_some(), &[List], "--search")?;
    only(r.output.is_some(), &[Plan], "--output")?;
    only(r.save, &[Plan], "--save")?;
    only(r.plan.is_some(), &[Clean], "--plan")?;
    only(r.fixture, &[Schedule, ScheduledRun], "--fixture")?;
    only(
        r.mode.is_some() || r.interval_hours.is_some() || r.unit_name.is_some(),
        &[Schedule],
        "--mode/--interval-hours/--unit-name",
    )?;
    if filters && !matches!(r.action, List | Plan | Help | Version) {
        return Err(usage("cli.filters_only_list_plan"));
    }
    if config && !matches!(r.action, Config | Help | Version) {
        return Err(usage("cli.config_requires_command"));
    }
    if r.action == Clean && r.plan.is_none() {
        return Err(usage("cli.clean_requires_plan"));
    }
    if r.output.is_some() && r.save {
        return Err(Failure::usage(Msg::new("cli.unknown").arg("--save")));
    }
    if let Some(s) = &r.sub {
        if !["status", "enable", "disable"].contains(&s.as_str()) {
            return Err(Failure::usage(Msg::new("cli.unknown").arg(s)));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Request, Failure> {
        parse(&s.split_whitespace().map(String::from).collect::<Vec<_>>())
    }

    #[test]
    fn rejects_invalid_combinations() {
        for bad in [
            "clean --yes",
            "plan --path /a --category npm",
            "scan --yes",
            "plan --category all",
            "scan --language fr",
            "scan --quick --worktrees",
            "list --worktrees",
            "scan --category npm",
            "plan --enable worktree",
            "plan --output",
            "scan extra",
            "plan --category swiftpm",
        ] {
            let r = p(bad);
            assert!(r.as_ref().is_err_and(|f| f.code == 2), "{bad} should fail with 2");
        }
    }

    #[test]
    fn accepts_reference_commands() {
        for good in [
            "scan",
            "scan --worktrees --json",
            "list --category worktree",
            "list --category worktree --ready",
            "config --enable worktree",
            "plan --category worktree --output ./worktree-plan.json",
            "clean --plan ./worktree-plan.json",
            "list --category worktree --filter pending --search feature",
            "schedule enable --mode analyze --interval-hours 24",
            "--help",
        ] {
            assert!(p(good).is_ok(), "{good} should parse");
        }
        assert_eq!(p("").unwrap().action, Action::Help);
        assert_eq!(p("scan --version").unwrap().action, Action::Version);
    }
}
