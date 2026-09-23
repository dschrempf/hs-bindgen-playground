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
