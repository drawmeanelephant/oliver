# Zig 0.17 build compatibility (with 0.16 retained)

## Summary

Makes Oliver's build work under **both** Zig 0.16.0 and 0.17.0, unblocking
boris issue #1025's "Oliver first" sequencing. Main's `ffa603e` had already
migrated to 0.17-only APIs (`Step.Run.addPassthruArgs`, `@backingInt`); this
branch restores 0.16 compat with two small, version-dispatched shims while
keeping everything 0.17-clean, and pins the honest floor.

- **`build.zig`** — new `addPassthruArgs(b, run)` helper branches at comptime
  on `@hasField(std.Build, "args")` (present in 0.16, removed in 0.17). 0.16
  forwards configure-time `b.args`; 0.17 calls `run.addPassthruArgs()`. The
  three call sites (`run`, `spec-conformance`, `cooklang-conformance`) use it.
  The dead branch is never analyzed on the other toolchain, so each side only
  references APIs that exist there.
- **`src/c_abi.zig`** — `@backingInt` (0.17-only; and 0.17's formatter rewrites
  `@intFromEnum`, making that spelling unstable under `zig fmt`) replaced by an
  explicit `abiCode` switch over the `Error` enum. The values mirror
  `include/oliver.h` exactly (0–10; the c-example CI leg already pins 0, 3, 4,
  5, 6, 7 behaviorally against the header constants), and the exhaustive
  switch forces any new `Error` member to pin its ABI value deliberately.
- **`build.zig.zon`** — `minimum_zig_version` back to `"0.16.0"`: the oldest
  toolchain the branch actually verifies. (Checked: Zig's package manager does
  not enforce a dependency's declared minimum when resolving — boris-on-0.16
  consumes oliver via URL pin either way — but the declared floor is honest
  evidence either way.)
- **CI (`ci.yml`)** — the test job becomes a `["0.16.0", "0.17.0"]` matrix
  (fail-fast off), running the full gate (tests + conformance + C ABI) on both
  legs; `zig fmt --check` runs on 0.17 only (its formatter is the canonical
  style; 0.16's is a strict subset on this tree).
- **Docs** — README/AGENTS/TESTS/ARCHITECTURE/C-ABI updated to state the dual
  toolchain support and where the version seams live.

## Why not 0.17-only?

Boris still builds its pinned Oliver under Zig 0.16 (its own issue #1025
tracks migrating to 0.17 as a separate, later step). Dual support lets boris
bump its Oliver pin (getting the `Build.args` fix) **before** its own 0.17
migration, so the two migrations don't have to land in lockstep. Dropping
0.16 now would force boris to flip everything in one move.

## Verification

All from clean caches, both toolchains (0.16.0 at
`/tmp/zig-aarch64-macos-0.16.0/zig`, 0.17.0 at `/opt/homebrew/bin/zig`):

| Gate | 0.16.0 | 0.17.0 |
| --- | --- | --- |
| `zig build test --summary all` | 25/25 steps; **504/504 tests** | 25/25 steps; **504/504 tests** |
| `zig build spec-conformance -- spec.txt --gate` (official CommonMark 0.31.2, SHA verified) | **652/652** expected passes | **652/652** |
| `zig build cooklang-conformance` (vendored canonical wall) | **60/60** | **60/60** |
| `zig build c-example-run` (C ABI compile + run) | pass | pass |
| `zig build` (install) + `oliver --version` | `oliver 1.1.0` | `oliver 1.1.0` |
| `zig fmt --check build.zig build.zig.zon src tests tools` | clean | clean |
| `zig build run -- render --from markdown` (passthru args actually land on argv) | `<h1>hi</h1>` | `<h1>hi</h1>` |
| `zig build cooklang-conformance -- tests/cooklang/canonical.yaml` (explicit path) | pass | pass |

No parser/renderer/model changes; no output bytes changed (conformance walls
byte-exact on both toolchains).

## For the reviewer

- The comptime dispatch uses `@hasField(std.Build, "args")` rather than a
  version-string compare: it detects the actual API difference that motivated
  the change. The `addPassthruArgs` call sits in the `else` branch, which 0.16
  never analyzes.
- `abiCode` is exhaustive over `Error`, so adding an error code without
  pinning its number is a compile error.
- CI cost roughly doubles for the test job (two legs). The 0.16 leg can be
  dropped once boris lands its own 0.17 migration and the floor moves.

## Downstream: boris pin-bump checklist (verified against a throwaway copy)

To keep the "result is better" claim concrete, I repointed a throwaway copy
of boris at this branch's tarball (branch `zig-0.17-compat`; package hash
`oliver-1.1.0-LOsZkKuUKADiYvOdtd6SD_AIFUHlHOsD0xnHeDKLAd03`, which is
content-derived and stable for every commit of this branch since only
`.paths`-filtered files ship) and built under
Zig 0.16 — boris's exact "Oliver pin first" sequencing from its #1025:

1. **The `Build.args` break is gone.** Oliver's `build.zig` configures and
   the dependency fetch resolves cleanly under 0.16 — the error from boris
   #1025 (`zig-pkg/oliver-…/build.zig:59: no field named 'args' in struct
   'Build'`) no longer reproduces. This was the only 0.16 blocker in oliver.
2. **`zig build -Doptimize=ReleaseSafe` is 21/21 green** (native + all wasm
   targets) after two small boris-side syncs that the wider oliver pin
   surfaces — pre-existing API drift from oliver's v1.1 feature work
   (raw-HTML policy knob + HTML 4.01 Strict profile, `a50aa15`/`f7bae1a`,
   merged before this branch), not from this change:
   - `src/render.zig` `RenderError`: add `RawHtmlRejected` and the five
     HTML4-Strict members (the set intentionally "tracks Oliver's public
     return type exactly" — this is the designed compile-time seam review
     firing).
   - `src/render_wasm.zig` `renderErr`: handle the new members (structurally
     unreachable; boris renders with the HTML profile).
3. **`zig build test` reaches 15484/15484 tests passing** once the full
   boris-side sync set below is applied (I applied all of it in the throwaway
   and re-ran). Every fix it needed is enumerated; there were no unknown
   unknowns beyond this list:
   - `src/render.zig` `RenderError`: add `RawHtmlRejected` and the five
     HTML4-Strict members (same class as the two build syncs — pre-existing
     API drift from oliver v1.1, merged on main before this branch).
   - `src/fuzz.zig:269`: same exhaustive-switch sync (test-only module).
   - `render.test.docs` pin guard: the `oliver-0.0.0-` hash prefix is
     hardcoded in three places (`hash_prefix` extraction, the doc needle
     construction, and the doc row itself); oliver's package version is now
     1.1.0, so boris should generalize the prefix to `oliver-` or bump it
     alongside the pins.
   - Doc pin citations: `docs/contracts/oliver-renderer.md` (Commit +
     Package hash rows) and `docs/contracts/fixtures/oliver-compat/MATRIX.md`
     (Pin line) — both must cite the new commit + full versioned hash
     (`oliver-1.1.0-…`).
   - `src/standard_site_publish.zig:39` `oliver_pin` const must match the
     zon revision.
   - Remaining 3/204 step failures are one root cause outside the pin:
     `tools/github-pages-audit/build.zig:49` still uses `b.args` and the
     test script shells out to bare `zig` (0.17 here). That leg is green
     under 0.16 (verified: 7/7) — it's boris's own #1025 migration work
     (the same `@hasField(std.Build, "args")` shim applies), independent of
     the oliver pin.

In short: with this branch, boris's `Build.args` blocker is resolved, and
the remaining boris card is the mechanical sync above — three error-set
switches, the pin citations, and generalizing the hardcoded `oliver-0.0.0-`
prefix. With those applied, boris is 15484/15484 tests green under 0.16 with
this branch pinned. The "Oliver first" critical path in boris #1025 is
unblocked.
