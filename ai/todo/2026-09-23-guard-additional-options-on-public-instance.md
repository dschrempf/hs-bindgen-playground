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
