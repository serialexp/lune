# Unicode Character Database 16.0.0 (vendored subset)

`UnicodeData.txt` from the Unicode 16.0.0 release, vendored so the build is
fully offline and reproducible (Rule Z-4 spirit: no network in the build).

- **Source:** <https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt>
- **Released:** 2024-09-10 (Unicode 16.0.0)
- **sha256:** `ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f`

## What uses it

`tools/gen_unicode_case.py` reads fields 12 (Simple_Uppercase_Mapping) and 13
(Simple_Lowercase_Mapping) to generate `src/gen/unicode_case.zig`, the SIMPLE
(1:1) case-mapping table behind `string.upper`/`string.lower` (design doc 06,
S-C). Regenerate with `just gen-unicode`.

## Bumping the Unicode version

This is a **determinism gate** (doc 06): the active version is recorded as the
`unicode_version` session effect, so old replays keep reproducing under their
recorded version. To pin a newer version: vendor that release's `UnicodeData.txt`
under `vendor/ucd/<version>/`, update the `just gen-unicode` recipe's `--version`
/ `--ucd` args, regenerate, and review. Bump rarely — case mapping is
stability-policy-protected and append-mostly.
