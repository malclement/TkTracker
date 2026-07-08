# Security Policy

## Supported versions

Only the latest release receives security fixes.

## TkTracker's security model

TkTracker is a local-only tool: it reads JSONL transcripts and the stats cache
under `~/.claude` (or `CLAUDE_CONFIG_DIR`) and Codex session rollouts under
`~/.codex` (or `CODEX_HOME`), and writes its own scan caches to
`~/Library/Application Support/TkTracker/`. It makes **no network requests**
and runs no shell commands. The main attack surface is therefore parsing of
untrusted transcript content — anything that makes either parser crash, hang,
or misattribute usage when fed a crafted JSONL line is in scope.

## Reporting a vulnerability

Please report vulnerabilities privately via
[GitHub's private vulnerability reporting](https://github.com/malclement/TkTracker/security/advisories/new)
rather than opening a public issue.

Include what you can: a proof-of-concept JSONL line or file, the version
(`TkTracker --version`), and your macOS version. You can expect an initial
response within a week. Once a fix ships, the issue will be disclosed in the
release notes with credit unless you prefer otherwise.
