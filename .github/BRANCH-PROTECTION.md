# Main-branch protection (draft, ready to apply)

Draft configuration for protecting `main`. It is deliberately **not yet
enabled** — it needs repository-admin access to apply, either through the
GitHub UI or the Rulesets API. The one check the ruleset requires is the CI
job from `.github/workflows/ci.yml`:

> **`fmt + tests + conformance gate`** — runs `zig fmt --check`, `zig build
> test` (148 tests), fetches the official CommonMark 0.31.2 corpus, and
> runs the classified conformance gate (652/652, 0 regressions).

If that check name ever changes (for example if the CI job is renamed or
split), update the ruleset to match, or merges to `main` will block.

## Option 1 — Apply in the GitHub UI

Repository **Settings → Rules → Rulesets → New ruleset → New branch
ruleset**:

1. **Name:** `Protect main`
2. **Enforcement status:** `Active`
3. **Bypass list:** remove every actor (the default entry is *Repository
   admin*). An empty list is the "no bypass" ask — nobody, not even the
   admin, skips the rules. If you later want an admin escape hatch, add the
   `Repository admin` role back deliberately.
4. **Targets:** `Include default branch` (this follows the default branch
   even if it is ever renamed).
5. **Rules** — add:
   - **Require a pull request before merging**
     - Required approvals: `1`
     - *Dismiss stale pull request approvals when new commits are pushed*:
       ON (a new push re-runs the gate)
     - *Require review from Code Owners*: ON (pairs with
       `.github/CODEOWNERS`)
     - *Require conversation resolution before merging*: ON
     - *Require the most recent push to be approved by someone other than
       the person who pushed it*: OFF for now (solo repo; turn ON when a
       second contributor joins)
   - **Require status checks to pass before merging**
     - Add check: search and select `fmt + tests + conformance gate`
     - *Require branches to be up to date before merging*: ON
   - **Block force pushes**: ON
   - **Block branch deletion**: ON (optional but recommended)
6. **Create.**

For comparison, the equivalent classic branch-protection route is
Settings → Branches → *Add branch protection rule* for `main`, checking
*Require a pull request*, *Require status checks*, and *Do not allow
bypassing the above settings* — but **rulesets are preferred** (they
supersede branch protection and apply the "no bypass" setting cleanly).

## Option 2 — Apply via the Rulesets API

The identical ruleset is ready in `.github/ruleset-main.json`. Requires an
admin-scoped token (repo *Administration* write permission):

```bash
gh api --method POST repos/drawmeanelephant/oliver/rulesets --input .github/ruleset-main.json
```

Or with a personal access token:

```bash
curl -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  https://api.github.com/repos/drawmeanelephant/oliver/rulesets \
  -d @.github/ruleset-main.json
```

Notes on the JSON:

- `"bypass_actors": []` — no actor bypasses the ruleset (the "no bypass"
  ask). Omitting the field instead allows repository admins to bypass.
- `strict_required_status_checks_policy: true` — the "branches up to date"
  requirement.
- `require_last_push_approval: false` — a solo developer cannot approve
  their own final push; flip to `true` when a second contributor joins.
- `allowed_merge_methods` is intentionally omitted: all of merge, squash,
  and rebase stay permitted.

## Pairing files

- `.github/CODEOWNERS` — every path is owned by the repository owner; with
  *Require review from Code Owners* ON, the owner must approve changes
  even from future collaborators.
- `.github/workflows/ci.yml` — the gate whose check this ruleset requires.
