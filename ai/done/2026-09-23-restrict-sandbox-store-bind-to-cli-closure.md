# Restrict the sandbox `/nix/store` bind to the CLI's closure

`buildArgv` binds all of `/nix/store` read-only into the bwrap sandbox
(`--ro-bind /nix/store /nix/store`). Attacker-controlled C can `#include` any
world-readable store path, and clang echoes the file's contents back as parse
errors, which the playground returns verbatim in the diagnostics panel. So the
whole store is an arbitrary-file-read primitive for anonymous users.

## Verified

Created a store file with a fake secret and included it:

```
#include "/nix/store/…-playground-demo-secret"
```

The `API_TOKEN=…` line came back tokenised in the diagnostics as clang errors
("use of undeclared identifier 'hunter2'"). Any world-readable store file works.

## Severity

Low on this single-purpose box: the store holds no secrets today (caddy's ACME
keys live in `/var/lib`, the playground has none), and NixOS treats the store as
world-readable by design. It matters because the *whole* store is exposed, incl.
the system closure — so anything a future module accidentally puts in the store
becomes readable, and it enumerates every package on the host.

## Fix

Bind only what the CLI needs instead of the entire store: compute the CLI's
runtime closure (`nix-store -qR` of the wrapper) and `--ro-bind` each path, or
bind the CLI's own out-path plus the closure roots. Keep it in `buildArgv`
alongside the other bwrap flags. Downside: `#include` of arbitrary system
headers outside the CLI's clang bundle would stop working — check the examples
still generate (they rely only on the CLI's bundled clang headers).

Alternative, if the closure enumeration is fiddly: accept the exposure for the
talk (nothing sensitive in the store) and revisit only if the box gains other
services.

## Outcome (2026-09-23): closure bound path by path

The enumeration was not fiddly — `closureInfo { rootPaths = runtimeDeps; }` in
`package.nix` writes the list, `makeWrapper --set PLAYGROUND_STORE_PATHS` points
the server at it, and `buildArgv` emits one `--ro-bind p p` per line. 78 paths
on the current pin; no measurable latency change (~0.29 s per request either
way). The config field is a `StoreBind` sum, so the whole-store branch is an
explicit named case rather than an empty list.

`cabal run` never touches the wrapper, so the dev shell sets the same variable
from `passthru.storePaths` — dev and deploy now bind identically, and a missing
runtime dep surfaces during iteration. Bare binary with no environment still
falls back to the whole store.

The predicted downside did not bite: every shipped example still generates (the
nixosTest runs all of them). Two checks added there — `#include` of
`/run/current-system/activate` now reports "file not found" where it previously
came back tokenised, and the `/etc/passwd` check still holds.

Note this narrows the primitive rather than removing it: the CLI's own closure
(glibc, gcc, its clang bundle) remains readable, as it must be. What is gone is
the system closure and any future secret a module drops into the store.
