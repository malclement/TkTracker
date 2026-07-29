# Resources

Data that ships inside the app bundle rather than being compiled into Swift.

## `pricing.json`

Vendor list prices per million tokens. Editing this file is how a price change
lands — no Swift edit, no release required for a user who wants to correct a
rate locally (Settings → Pricing writes overrides to
`~/Library/Application Support/TkTracker/pricing-overrides.json`, which win over
this table).

Rules are evaluated **in order**. A rule applies when *every* substring in its
`match` array appears in the lowercased model id, so `["gpt-5", "mini"]` matches
`gpt-5.1-mini` but not `gpt-5.1-codex`. Put specific rules above general ones.

- `vendor` picks the cache multipliers: `anthropic` bills cache reads at 0.1×
  input, 5-minute writes at 1.25× and 1-hour writes at 2×; `openai` bills cached
  input at 0.1× and never charges for cache writes. Omit it and the vendor is
  inferred from the id.
- `skip: true` marks a model as deliberately unpriced. It is still tracked in
  tokens and flagged "no pricing" in the UI. This is why an unrecognised GPT
  generation shows no cost instead of silently borrowing the previous
  generation's rate.

`PricingCatalog.builtIn` mirrors this file in Swift. It is the fallback for any
build that cannot reach the resource bundle, so the CLI and the test suite price
identically to the app even without it. **Keep the two in sync when editing.**

## `en.lproj/Localizable.strings`

Base localization. English is the development language, so most view copy is
inline and resolves to itself; this table holds strings assembled in code and
those shared across surfaces.

To add a language, copy the directory to `<code>.lproj` (e.g. `fr.lproj`) and
translate the values only — the keys are identifiers and must not change.
