# Security Policy

## Reporting a vulnerability

Please do not open public issues for security problems.

Report privately through GitHub: open this repository's **Security** tab
and choose **Report a vulnerability**. That opens a private channel with
the maintainers — it stays private until we agree on disclosure with you.

Include what you ran, what you expected, and what happened, plus a minimal
reproduction if you have one. This is a small project, so responses are
best effort — but we will acknowledge your report and coordinate a fix and
disclosure with you.

## Supported versions

Fixes land on the default branch and ship in the next release. We don't
maintain backport branches for security fixes.

## Scope

In scope: anything that could genuinely harm a user of this project —
data loss, file writes outside the project's own directories, secrets
leaking into logs or output, crashes or hangs on crafted input, and
dependency or supply-chain problems.

Out of scope: bugs with no security impact — file those as normal issues,
they're welcome too.
