# GitHub model — the exact commands the scripts wrap

The structure: **Epic issue** (parent) → **native sub-issues** (work items) → on the **standing org
Project** board, with a **per-investigation saved view**. Closing a sub-issue moves the Epic's progress bar
*and* the board, for free. This file is the command reference; the scripts automate it.

## Sub-issues (issue → issue; PRs can't be sub-issues)
```bash
# attach issue #CHILD as a sub-issue of epic #EPIC (needs the child's REST id, not its number)
child_id=$(gh api repos/OWNER/REPO/issues/CHILD --jq .id)
gh api --method POST repos/OWNER/REPO/issues/EPIC/sub_issues -F sub_issue_id=$child_id

# list / check existing sub-issues (idempotency)
gh api repos/OWNER/REPO/issues/EPIC/sub_issues --jq '.[].number'

# native progress bar (no computation needed — GitHub derives it)
gh api repos/OWNER/REPO/issues/EPIC --jq '.sub_issues_summary'   # {total, completed, percent_completed}

# a sub-issue's parent (authoritative)
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){issue(number:CHILD){parent{number}}}}'
```
An issue has **one** parent. Re-parenting moves it; it can't belong to two Epics — use the board for
many-to-many membership instead.

## Project board (Projects v2)
```bash
# discover (needs `project` scope: gh auth refresh -s project)
gh project list --owner OWNER
gh project view N --owner OWNER --format json            # .id = PVT_… (project node id)
gh project field-list N --owner OWNER --format json      # field ids + single-select option ids

# add an issue or PR (PRs are valid items, just not sub-issues)
gh project item-add N --owner OWNER --url <issue-or-pr-url> --format json   # .id = item id

# set a single-select field (Status / Priority)
gh project item-edit --id <item-id> --project-id <PVT_…> \
  --field-id <field-id> --single-select-option-id <option-id>
```
Built-in fields worth knowing: **Sub-issues progress** (the bar, per row), **Parent issue**
(auto-derived from the sub-issue link — this is what `parent-issue:` view filters key on), **Status**
(set a project workflow to auto-move closed items to Done). The **Insights** tab gives progress-over-time
charts automatically.

## Per-investigation view — UI-only (cannot be scripted)
There is no API to create a Project view. Always print the filter for the user to save once:
```
parent-issue:OWNER/REPO#EPIC        # optionally + is:open for a "what's next" board
```
Layout: Board grouped by Status, with Priority + Sub-issues progress as visible fields.

## Scope degradation
`gh auth status` shows token scopes. Without `project`/`read:project`, sub-issues still work (issues
API only); skip every `gh project …` step with a one-line note and tell the user to
`gh auth refresh -s project` if they want the board.
