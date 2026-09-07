# Source adapter review — 2026-09-07

Claude Code and Codex use the `SourceAdapter` contract and a shared scan,
archive and accounting pipeline. Each profile owns its parser and deduplication
state. Gemini CLI and OpenCode remain outside automatic discovery in this
release.

## Gemini CLI

The [upstream session types](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)
now include JSONL records, metadata updates (`$set`) and rewinds (`$rewindTo`).
Assistant records distinguish prompt, cached, candidate-output, thought and tool
usage. A parser that sums every JSONL line or only supports older JSON snapshots
would be insufficient. Before enabling this adapter, pin an upstream version and
verify append/update/rewind, compaction, subagent attribution and cache/thought
billing against independently calculated fixtures. Keep provider quotas separate
from API-equivalent value.

## OpenCode

The [upstream session implementation](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/message-v2.ts)
uses database-backed messages and imports schema types from its core package.
The [export command](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/cli/cmd/export.ts)
is a better initial integration boundary than opening a live SQLite database.
The next adapter should consume a pinned, sanitized export fixture and verify
provider-specific input/cache/reasoning semantics, retries and compaction.
Do not count both message aggregates and step parts.

This review changes the integration contract and records the remaining acceptance
criteria. It does not claim support for either source before those criteria pass.
