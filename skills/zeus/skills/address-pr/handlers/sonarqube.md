# SonarQube Handler

Fix SonarQube quality gate issues.

See `references/handler-contract.md` for shared rules.

## Fix

### 0. Prerequisites

```bash
PROJECT_KEY=$(bash ${CLAUDE_SKILL_DIR}/scripts/find-sonar-project-key.sh) || {
  # Exit 2 means SonarQube isn't wired up here. Append a no-op outcome and return.
  bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append sonarqube \
    '{"fixed":0,"declined":0,"skipped":0,"unresolved":[{"note":"no sonar.projectKey configured"}]}'
  exit 0
}
```

The script checks `.sonarlint/connectedMode.json`, `sonar-project.properties`, `pom.xml`, and `package.json` (in that order) and prints the resolved key on stdout. Exit 2 = no key configured.

### 1. Query quality gate and open issues

```
mcp__sonarqube__get_project_quality_gate_status(projectKey, pullRequest: PR_NUMBER)
mcp__sonarqube__search_sonar_issues_in_projects(project: PROJECT_KEY, pullRequest: PR_NUMBER, statuses: ["OPEN", "CONFIRMED"])
```

### 2. Fix each open issue

For each issue:

1. Read the reported file:line.
2. For unfamiliar rules, call `mcp__sonarqube__show_rule`.
3. Apply an Edit.

- **FIX** bugs, code smells, reliability issues directly.
- **SKIP** `VULNERABILITY` and `SECURITY_HOTSPOT` — flag for manual review.
- **Mark WONTFIX** false positives via `mcp__sonarqube__change_sonar_issue_status`.

Append outcome:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append sonarqube \
  '{"fixed":N,"declined":0,"skipped":N,"unresolved":[…]}'
```

## Standalone mode

`/zeus:address-pr sonarqube`: exit when quality gate OK and zero open issues.
