# Golden corpus — expected values, derived by hand

These numbers are computed from the published rates, **not** captured from a run
of TkTracker. That is the point: a snapshot test only proves the code still does
what it did, while these prove it does the right thing. If a change makes
`GoldenCorpusTests` fail, either the change is wrong or a rate moved — and if a
rate moved, this file must be re-derived and `pricing.json` updated alongside.

Token counts are all round millions so every product is exact in decimal and
nobody has to trust a float.

## Rates used

| Model | Input $/MTok | Output $/MTok | Cache read | 5m write | 1h write |
|---|---|---|---|---|---|
| `claude-opus-4-8` | 5 | 25 | 0.5 (0.1×) | 6.25 (1.25×) | 10 (2×) |
| `claude-sonnet-4-5` | 3 | 15 | 0.3 | 3.75 | 6 |
| `claude-haiku-4-5` | 1 | 5 | 0.1 | 1.25 | 2 |
| `gpt-5.5` | 5 | 30 | 0.5 (0.1×) | n/a | n/a |

Web search: $10 per 1,000 requests.

## Claude — `s1.jsonl`

`m1` / `r1` (Opus 4.8), appearing **twice** as two content-block lines of one
streamed turn. The second occurrence must be deduped by `(messageId, requestId)`.

| Component | Tokens | Rate | Cost |
|---|---|---|---|
| input | 1,000,000 | 5 | 5.00 |
| output | 1,000,000 | 25 | 25.00 |
| cache read | 1,000,000 | 0.5 | 0.50 |
| cache write 5m | 1,000,000 | 6.25 | 6.25 |
| cache write 1h | 1,000,000 | 10 | 10.00 |
| **m1 total** | **5,000,000** | | **46.75** |

`m2` / `r2` (Sonnet 4.5) with 1,000 web searches:

| Component | Amount | Rate | Cost |
|---|---|---|---|
| input | 1,000,000 | 3 | 3.00 |
| output | 0 | 15 | 0.00 |
| web search | 1,000 req | 10 / 1K | 10.00 |
| **m2 total** | **1,000,000 tok** | | **13.00** |

**s1: 6,000,000 tokens, 2 messages, $59.75**

## Claude — `s2.jsonl`

A resumed session. Its first line replays `m1`/`r1` verbatim from `s1`; the
cross-file claim table must attribute it to `s1` and count it **zero** more
times. Only `m3` is new.

`m3` / `r3` (Haiku 4.5):

| Component | Tokens | Rate | Cost |
|---|---|---|---|
| input | 1,000,000 | 1 | 1.00 |
| output | 1,000,000 | 5 | 5.00 |
| **m3 total** | **2,000,000** | | **6.00** |

**s2: 2,000,000 tokens, 1 message, $6.00**

**Claude total: 8,000,000 tokens, 3 messages, $65.75**

## Codex — one `gpt-5.5` call

The rollout reports `input_tokens: 1,000,000` with `cached_input_tokens:
500,000`. Codex's `input_tokens` is inclusive of the cached portion, so the
parser splits it: 500,000 fresh input and 500,000 cache reads.

| Component | Tokens | Rate | Cost |
|---|---|---|---|
| input (fresh) | 500,000 | 5 | 2.50 |
| cached input | 500,000 | 0.5 | 0.25 |
| output | 1,000,000 | 30 | 30.00 |
| **total** | **2,000,000** | | **32.75** |

**Codex total: 2,000,000 tokens, 1 message, $32.75**

## Grand total

| | Tokens | Messages | Cost |
|---|---|---|---|
| Claude | 8,000,000 | 3 | 65.75 |
| Codex | 2,000,000 | 1 | 32.75 |
| **All** | **10,000,000** | **4** | **98.50** |

## Other properties the corpus pins

- **Branches.** `s1` is on `main`, `s2` on `feature/golden`. Branch attribution
  follows the digest's last-seen branch, so the two sessions land on different
  branch rows within one project.
- **Project merge.** All three files record `cwd = /Users/x/Documents/golden`,
  and the Codex rollout encodes the same cwd into its project dir, so Claude and
  Codex usage merge into a single project row.
- **Context window.** The Codex call reports `model_context_window: 272000`,
  which must win over the per-model table.
