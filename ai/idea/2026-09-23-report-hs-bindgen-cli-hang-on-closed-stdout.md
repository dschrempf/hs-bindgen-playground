# Report upstream: `hs-bindgen-cli` hangs when stdout is closed

`hs-bindgen-cli` never exits on its error path if fd 1 is closed (as opposed to
redirected). It succeeds normally; only the error path hangs. Worth filing
against `well-typed/hs-bindgen`.

## Reproducer

```sh
T=$(mktemp -d); cd "$T"; mkdir out
printf 'struct { oops\n' > input.h
timeout --signal=KILL 5s hs-bindgen-cli -v0 preprocess \
  --single-file --safe '' --unique-id p --module D \
  --hs-output-dir out --create-output-dirs --overwrite-files \
  -I . input.h >&-        # note: >&- closes fd 1, it does not redirect it
echo "exit=$?"
```

| stdio                   | exit | elapsed |
| ----------------------- | ---- | ------- |
| `>&-` (closed)          | 137  | 5.008 s |
| `>/dev/null`            | 3    | 0.033 s |
| `<&-` (stdin closed)    | 3    | 0.028 s |

So it is stdout specifically, and closed specifically.

## Scope

Not a regression: reproduced on both `bc36a739` (the pin before the
2026-09-23 flake update) and `a55d5f9a` (after). Presumably present much
longer.

Not diagnosed further — the guess is that something on the error path writes to
stdout and blocks, but that was not confirmed, so the report should stick to the
observation.

## Status here

Worked around, so nothing is waiting on the upstream fix: the playground's
`runCapture` passes `/dev/null` handles instead of `NoStream`. Before that, every
failing generation stalled for the full `PLAYGROUND_TIMEOUT_SECONDS` and the user
saw diagnostics with no hint that anything had been killed.
