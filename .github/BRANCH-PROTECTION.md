# Main-branch protection

The `Protect main` ruleset is **applied and active** on this repository
(`enforcement: active`, `bypass_actors: []`). This document is the
source of truth for what it enforces, how it was applied, and what to
flip when the project gains a second contributor.

The one check the ruleset requires is the CI job from
`.github/workflows/ci.yml`:

> **`fmt + tests + conformance gate`** — runs `zig fmt --check`, `zig build
> test` (148 tests), fetches the official CommonMark 0.31.2 corpus, and
> runs the classified conformance gate (652/652, 0 regressions).

If that check name ever changes (for example if the CI job is renamed or
split), update the ruleset to match, or merges to `main` will block.

## What the ruleset enforces

- **Pull requests only** — no direct pushes to `main`. In a solo repo the
  only path in is a PR, and with `bypass_actors: []` even the repository
  admin cannot force a merge.
- **Required CI check** — `fmt + tests + conformance gate` must pass, with
  *branches up to date* (`strict_required_status_checks_policy: true`), so
  every merge runs against the latest `main`.
- **Solo mode: `required_approving_review_count: 0`** — GitHub does not
  allow a PR author to approve their own pull request (verified
  empirically: `GraphQL: Review Can not approve your own pull request`),
  so with 1 required approval and one contributor, every PR deadlocks and
  `main` becomes unmergeable. With 0 approvals the status check is the
  gate: green CI = mergeable.
- **Block force pushes** (`non_fast_forward`) and **block branch
  deletion** (`deletion`).
- **No bypass** — `bypass_actors: []`; nobody, not even the admin, skips
  the rules.

## When a second contributor joins

In one edit to `.github/ruleset-main.json` (then `PATCH` via the API, or
the UI toggles), flip the solo-mode values back to collaborative mode:

- `required_approving_review_count`: `0` → `1`
- `require_code_owner_review`: `false` → `true` (pairs with
  `.github/CODEOWNERS`)
- `require_last_push_approval`: keep `false` unless you want the final
  push to a PR approved by someone other than the pusher.

Keep everything else (status checks, strict policy, no bypass, force-push
and deletion blocks) unchanged.

## Reapplying or modifying

UI: Repository **Settings → Rules → Rulesets → Protect main** → Edit.

API: `.github/ruleset-main.json` is the current payload. With an
admin-scoped token (repo *Administration* write permission):

```bash
gh api --method PUT repos/drawmeanelephant/oliver/rulesets/<id> --input .github/ruleset-main.json
```

Notes on the JSON:

- `"bypass_actors": []` — no actor bypasses the ruleset (the "no bypass"
  ask). Omitting the field instead allows repository admins to bypass.
- `strict_required_status_checks_policy: true` — the "branches up to date"
  requirement.
- `allowed_merge_methods` is intentionally omitted: all of merge, squash,
  and rebase stay permitted.

## Pairing files

- `.github/CODEOWNERS` — every path is owned by the repository owner;
  relevant once `require_code_owner_review` is turned back on.
- `.github/workflows/ci.yml` — the gate whose check this ruleset requires.
