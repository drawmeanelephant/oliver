# Contributing to Oliver

Thanks for being here. Contributions of every size are welcome — bug
reports, fixes, docs, tests, features, and honest questions. You don't need
permission to help, and you don't need to be an expert. If something looks
wrong or confusing, that is useful signal: please tell us.

Oliver is the Markdown library Boris renders with.

## Getting set up

This project builds with Zig. The pinned or minimum version is declared in
`build.zig.zon` — use that or newer. Then:

    zig build       # compile
    zig build test  # run the test suite

If anything in this section or the README is stale, fixing it is a great
first contribution.

## Ways to contribute

- **Report bugs.** Open an issue with what you did, what you expected, and
  what happened. Minimal reproductions and version info help enormously.
  Blank issues are fine — a clear description beats a template.
- **Suggest features.** Open an issue describing the problem you want to
  solve before building something large. A short conversation up front
  saves real rework.
- **Send small PRs.** Typos, fixes, tests, doc corrections — focused PRs
  are the fastest to review and the most likely to land quickly. Forks are
  welcome: branch from `main` and open the PR against `main`.
- **Improve docs.** Unclear README sections, stale instructions, missing
  examples: all fair game.

## What a good PR looks like

- **Focused.** One change per PR beats one big PR every time.
- **Tested.** `zig build test` passes before you push. If you cannot run it, say so.
- **Honest.** Say what changed, why, and how you verified. "I didn't
  test X" is a perfectly acceptable thing to write — pretending you did
  is not.
- **Linked.** Reference the issue as "Closes #123" (or "Refs #123" if it
  should stay open) and GitHub wires it up automatically.

It's fine to open a draft PR early. Feedback on direction is much cheaper
than feedback on a finished diff.

## Style notes

- Match the code around you. Consistency with existing style matters more
  than personal preference.
- Keep diffs minimal — no drive-by reformatting of code you didn't touch.
- AI-assisted contributions are welcome — the bar is the same, and you own
  what you submit.

## Conduct

Be kind and assume good intent. Disagree with ideas, not people.
Harassment isn't welcome; maintainers will remove it and, if needed, the
people doing it. If you need to raise a conduct issue privately, contact
the maintainer through their GitHub profile.

## License

MIT, no CLA. By contributing, you agree that your contributions are
licensed under the same terms as the project — see [LICENSE](LICENSE).
