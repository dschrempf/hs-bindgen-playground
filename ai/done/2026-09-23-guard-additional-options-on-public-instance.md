# Constrain the "Additional options" field on the public instance

The UI's *Additional options* box flows through `splitArgs` straight onto the
`hs-bindgen preprocess` argv (`cliArgs`). There is no shell — args go to
`createProcess` as an argv list — so there is no injection, but it does hand
anonymous users the full `preprocess` + `--clang-option=…` surface.

## What's already contained

- Duplicate of a fixed flag errors out: passing a second `--hs-output-dir`
  makes the CLI reject the invocation, so output can't be redirected out of
  `/work`. Verified.
- Writes are confined by bwrap (`/work` + `/tmp` tmpfs only) and `prlimit
  --fsize`; the file read primitive via `--clang-option=-I…` is no worse than a
  plain `#include` (see the store-bind todo).
- `maxOptionsLen` caps the string at 512 chars.

So this adds no new *class* of attack beyond what a crafted header already
grants — the sandbox contains the outcome either way. It's flagged because it's
a broad, unvalidated flag surface exposed to the public, and clang has many
options whose behaviour under the sandbox hasn't been enumerated.

## Fix (pick one for the public instance)

- Simplest: hide/disable the field in `static/index.html` for the public
  deployment, keeping it for local use.
- Or whitelist a small set (`--select-all`, `-D`, `-I` within `/work`) and
  reject the rest in `validate`, turning the free-form string into a checked
  domain type rather than passthrough.

Low priority given the sandbox holds; do it only if trimming attack surface for
the exposure is worth the UI change.

## Outcome (2026-09-23): allowlisted, no toggle

Took the second fix, for every instance rather than just the public one — the
field stays in the UI but is now a checked domain type. `validate` returns a
`Job` (the wire `GenReq` with each free-form field already parsed), carrying
`[ExtraOpt]`; `parseExtraOpts` matches each token against `allowedOpts`, a table
of flag → argument count, and rejects everything else with the accepted list in
the message. `cliArgs` and `displayCommand` both render from that list, so the
options string is parsed once instead of re-split in each.

Allowed: the flags whose effect is confined to hs-bindgen's own behaviour
(`--select-*`, `--enable-program-slicing`, `--omit-field-prefixes`,
`--parse-empty-macros`, `--post-qualified-imports`, `--fblocks`, `--no-stdlib`,
`--binding-spec-allow-newer`, `--path-style`, `--hash-define NAME VALUE`).
Rejected: anything naming a file or include dir, anything reaching clang, and
anything `cliArgs` already fixes — so the `--clang-option=-I…` file-read
primitive is gone, not just contained.

The `-D FOO=1` in the old UI placeholder was never valid for `preprocess`
anyway; replaced with `--select-all --hash-define FOO 1`. PCRE arguments stay
attacker-controlled — a pathological pattern only burns the job's own
`prlimit --cpu`. Covered by a nixosTest check.
