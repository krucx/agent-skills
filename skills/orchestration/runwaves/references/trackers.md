# Trackers beyond GitHub

Load when an item or epic parent is a Linear or Jira key (`ENG-123`, `PROJ-7`). GitHub issues stay
inline in the planning steps (`gh`).

- **Reach**: `superset tasks get <KEY> --tracker linear --json`, or the harness's own tools. Not
  reachable: stop and say how to connect (Linear in Paradev, or `superset plugins install
  linear`). Never install or connect anything yourself.
- **Fetch**: title, body, labels, author, as for any item; the same drop rules apply.
- **Parents** (`feature ENG-40`): read the children with `superset tasks get <KEY> --tracker linear
  --json`; none reachable: say how to connect, stop. `epic.sh` is GitHub sub-issues only, so put the
  integration (`epic` set to `{id, title, url}`) and the children as its items into the draft plan
  before the go, with dependencies among them as for any items; `plan.sh write` saves it at the go.
  After the go, only scripts change `integrations`.
- Still drop items with an open PR, and name each drop and why.
