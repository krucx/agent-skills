# Trackers beyond GitHub

Load when an item or epic parent is a Linear or Jira key (`ENG-123`, `PROJ-7`). GitHub issues stay
inline in SKILL.md (`gh`).

- **Reach**: `superset tasks get <KEY> --tracker linear --json`, or the harness's own tools. Not
  reachable: stop and say how to connect (Linear in Paradev, or `superset plugins install
  linear`). Never install or connect anything yourself.
- **Fetch**: title, body, labels, author, as for any item; the same drop rules apply.
- **Parents** (`feature ENG-40`): read the children with `superset tasks get <KEY> --tracker linear
  --json`; none reachable: say how to connect, stop. Add the integration by hand with `epic` set
  (`{id, title, url}`), the children as its queued items, then dependencies among them as for any
  items. `epic.sh` is GitHub sub-issues only.
- Still drop items with an open PR, and name each drop and why.
