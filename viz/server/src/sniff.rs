#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PlanKind {
    Ceo,
    Eng,
    Unknown,
}

const SCAN_LINES: usize = 40;

pub fn sniff_kind(filename: &str, body: &str) -> PlanKind {
    let lower_name = filename.to_lowercase();
    let head: String = body
        .lines()
        .take(SCAN_LINES)
        .collect::<Vec<_>>()
        .join("\n")
        .to_lowercase();

    let is_ceo = lower_name.contains("ceo")
        || head.contains("ceo/founder-mode plan review")
        || head.contains("scope expansion")
        || head.contains("selective expansion")
        || head.contains("from /plan-ceo-review")
        || head.contains("plan-ceo-review");

    let is_eng = lower_name.contains("eng")
        || head.contains("eng manager-mode plan review")
        || head.contains("from /plan-eng-review")
        || head.contains("plan-eng-review")
        || (head.contains("## architecture") && head.contains("## edge cases"));

    match (is_ceo, is_eng) {
        (true, false) => PlanKind::Ceo,
        (false, true) => PlanKind::Eng,
        (true, true) => PlanKind::Eng,
        _ => PlanKind::Unknown,
    }
}

pub fn extract_title(body: &str) -> Option<String> {
    body.lines()
        .find(|line| line.starts_with("# "))
        .map(|line| line.trim_start_matches('#').trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ceo_filename_wins() {
        assert_eq!(sniff_kind("agentkeys-ceo-plan.md", "no body"), PlanKind::Ceo);
    }

    #[test]
    fn eng_body_marker() {
        let body = "# Plan\n\nfrom /plan-eng-review\n";
        assert_eq!(sniff_kind("vague-name.md", body), PlanKind::Eng);
    }

    #[test]
    fn unknown_default() {
        assert_eq!(sniff_kind("random-slug.md", "## Just a plan"), PlanKind::Unknown);
    }

    #[test]
    fn extract_h1_title() {
        let body = "# My Title\nstuff";
        assert_eq!(extract_title(body), Some("My Title".to_string()));
    }
}
