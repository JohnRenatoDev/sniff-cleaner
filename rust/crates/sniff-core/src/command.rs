//! Runs fixed external programs with argv only (never a shell), a reduced
//! environment, a timeout and an output cap.

use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const OUTPUT_LIMIT: usize = 24_000_000;

#[derive(Debug, Clone)]
pub struct Output {
    /// Exit status, or -1 when the process was killed, timed out or its
    /// output exceeded the limit.
    pub status: i32,
    pub stdout: Vec<u8>,
    pub timed_out: bool,
}

impl Output {
    pub fn ok(&self) -> bool {
        self.status == 0 && !self.timed_out
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }
}

const KEPT_ENV: &[&str] = &[
    "HOME",
    "USER",
    "LOGNAME",
    "TMPDIR",
    "XDG_CONFIG_HOME",
    "XDG_RUNTIME_DIR",
];

pub fn run(program: &Path, args: &[&str], cwd: Option<&Path>, timeout: Duration) -> Output {
    let mut cmd = Command::new(program);
    cmd.args(args)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for key in KEPT_ENV {
        if let Some(v) = std::env::var_os(key) {
            cmd.env(key, v);
        }
    }
    cmd.env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .env("PATH", "/usr/local/bin:/usr/bin:/bin");
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let failed = Output {
        status: -1,
        stdout: Vec::new(),
        timed_out: false,
    };
    let Ok(mut child) = cmd.spawn() else { return failed };
    let mut stdout = child.stdout.take().expect("piped stdout");
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 65536];
        loop {
            match stdout.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if buf.len() + n > OUTPUT_LIMIT {
                        return (buf, true);
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
            }
        }
        (buf, false)
    });
    let start = Instant::now();
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st.code().unwrap_or(-1),
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = rustix::process::kill_process(
                        rustix::process::Pid::from_child(&child),
                        rustix::process::Signal::TERM,
                    );
                    std::thread::sleep(Duration::from_millis(80));
                    let _ = child.kill();
                    let _ = child.wait();
                    timed_out = true;
                    break -1;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
            Err(_) => break -1,
        }
    };
    let (stdout, overflow) = reader.join().unwrap_or_default();
    if overflow {
        let _ = child.kill();
        return Output {
            status: -1,
            stdout: Vec::new(),
            timed_out,
        };
    }
    Output {
        status,
        stdout,
        timed_out,
    }
}
