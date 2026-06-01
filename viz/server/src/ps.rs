use regex::Regex;
use serde::Serialize;
use std::process::Stdio;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BattleKind {
    CargoTest,
    Claude,
    Codex,
    Ralph,
    Provisioner,
    Other,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Battle {
    pub pid: u32,
    pub kind: BattleKind,
    pub label: String,
    pub crate_name: Option<String>,
}

pub async fn snapshot() -> anyhow::Result<Vec<Battle>> {
    let output = Command::new("ps")
        .args(["-A", "-o", "pid=,command="])
        .stdout(Stdio::piped())
        .output()
        .await?;
    let text = String::from_utf8_lossy(&output.stdout);
    Ok(parse_ps(&text))
}

pub fn parse_ps(text: &str) -> Vec<Battle> {
    let cargo_test_re = Regex::new(r"\bcargo\s+(test|nextest)\b").unwrap();
    let pkg_flag_re = Regex::new(r"-p\s+([\w-]+)").unwrap();
    let claude_re = Regex::new(r"(^|/)claude(\s|$)").unwrap();
    let codex_re = Regex::new(r"(^|/)codex(\s|$)").unwrap();
    let ralph_re = Regex::new(r"(omc\b|oh-my-claudecode)").unwrap();
    let prov_re = Regex::new(r"node\b.*provisioner-scripts").unwrap();

    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim_start();
        let Some((pid_str, cmd)) = line.split_once(' ') else {
            continue;
        };
        let Ok(pid) = pid_str.trim().parse::<u32>() else {
            continue;
        };
        let cmd = cmd.trim();

        if cargo_test_re.is_match(cmd) {
            let crate_name = pkg_flag_re
                .captures(cmd)
                .and_then(|c| c.get(1))
                .map(|m| m.as_str().to_string());
            let label = match crate_name.as_deref() {
                Some(c) => format!("cargo test -p {c}"),
                None => "cargo test".to_string(),
            };
            out.push(Battle {
                pid,
                kind: BattleKind::CargoTest,
                label,
                crate_name,
            });
            continue;
        }
        if claude_re.is_match(cmd) {
            out.push(Battle {
                pid,
                kind: BattleKind::Claude,
                label: "claude".into(),
                crate_name: None,
            });
            continue;
        }
        if codex_re.is_match(cmd) {
            out.push(Battle {
                pid,
                kind: BattleKind::Codex,
                label: "codex".into(),
                crate_name: None,
            });
            continue;
        }
        if ralph_re.is_match(cmd) {
            out.push(Battle {
                pid,
                kind: BattleKind::Ralph,
                label: "ralph".into(),
                crate_name: None,
            });
            continue;
        }
        if prov_re.is_match(cmd) {
            out.push(Battle {
                pid,
                kind: BattleKind::Provisioner,
                label: "provisioner-scripts".into(),
                crate_name: None,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cargo_test_with_pkg() {
        let line = "12345 /usr/bin/cargo test -p agentkeys-types --lib";
        let battles = parse_ps(line);
        assert_eq!(battles.len(), 1);
        assert_eq!(battles[0].kind, BattleKind::CargoTest);
        assert_eq!(battles[0].crate_name.as_deref(), Some("agentkeys-types"));
    }

    #[test]
    fn parses_claude() {
        let line = "555 /Users/x/.local/bin/claude --resume";
        let battles = parse_ps(line);
        assert_eq!(battles.len(), 1);
        assert_eq!(battles[0].kind, BattleKind::Claude);
    }

    #[test]
    fn ignores_unrelated() {
        let line = "1 /sbin/launchd\n2 /bin/zsh";
        assert!(parse_ps(line).is_empty());
    }

    #[test]
    fn parses_ralph() {
        let line = "999 /opt/oh-my-claudecode/bin/omc team";
        let battles = parse_ps(line);
        assert_eq!(battles.len(), 1);
        assert_eq!(battles[0].kind, BattleKind::Ralph);
    }
}
