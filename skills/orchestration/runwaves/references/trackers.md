# Trackers beyond GitHub

Load for a Linear or Jira key (`ENG-123`, `PROJ-7`) as item or epic parent. GitHub stays in SKILL.md.

- **Reach**: `superset tasks get <KEY> --tracker linear --json`, or the harness's own tools.
  Unreachable: stop, say how to connect (Linear in Paradev, or `superset plugins install linear`).
  Never install or connect anything yourself.
- **Fetch** title, body, labels, author; same drop rules (incl. an open PR), naming each and why.
- **Parents** (`feature ENG-40`): children via the same `tasks get`; none reachable: say how to
  connect, stop. `epic.sh` is GitHub-only, so put the integration (`epic` = `{id, title, url}`) and
  children as its items, with dependencies, into the draft before the go; `plan.sh write` saves it.
  After the go only scripts change `integrations`.
