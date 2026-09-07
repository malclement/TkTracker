# Pricing catalog

`pricing.json` is the authoritative bundled catalog. Run
`python3 Scripts/generate_pricing.py` after editing it; CI's `--check` verifies
the compiled fallback is identical. This is a bundled data update, so changing
shipped prices still requires distributing a new app build. There is no remote
pricing download.

Schema 2 rules use exact canonical `ids`, USD-per-million `input`, `output`,
`cacheRead`, `cacheWrite5m` and `cacheWrite1h` rates, and a primary `sourceURL`.
Optional context thresholds, fast multipliers, validity dates and review dates
preserve billing distinctions. Unknown models and unsupported observed tiers
remain unpriced. Missing tiers use standard estimates with a coverage notice.
Historical usage is valued with this catalog unless a dated rule specifies an
effective period; this is not an invoice reconstruction.

Overrides are keyed by canonical model ID and saved atomically in
`~/Library/Application Support/TkTracker/pricing-overrides.json`. Existing exact
legacy display-name overrides are still read. Finite, nonnegative values only;
a failed save retains the previous rates and surfaces the failure.

Pricing sources checked September 7, 2026:

- [OpenAI pricing](https://developers.openai.com/api/docs/pricing)
- [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing)

GPT-5.6 Sol's promotional rate requires review on November 21, 2026.
