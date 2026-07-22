# hs-bindgen-playground

Public web service for a MuniHac talk: paste a C header → get Haskell bindings.
A scotty server shells out to the Nix-built `hs-bindgen-cli` (pinned flake input)
inside a bubblewrap sandbox. Deployed with Nix.

## Commands

```sh
nix develop            # toolchain: ghc, cabal, hs-bindgen-cli (bundles clang+doxygen), bwrap
cabal run              # fast iteration; or `nix run .#` for the fully-wrapped binary
(cd app && ghc -fno-code -Wall Main.hs)   # quickest typecheck (deps are in the dev shell)
nix build .#packages.x86_64-linux.default # wrapped server (validates package.nix)
nix build .#checks.x86_64-linux.integration   # nixosTest: boots module, generates in a VM
nix flake check                           # eval everything + run the test
```

## Layout

- `app/Main.hs` — the whole server: routes, validation, concurrency gate, and the
  `timeout → prlimit → bwrap → hs-bindgen-cli` shell-out. All config via `PLAYGROUND_*` env.
- `nix/package.nix` — `callCabal2nix` + `makeWrapper` putting runtime tools on PATH.
- `nix/module.nix` — NixOS module (hardened systemd unit + optional caddy/ACME).
  Applied as `nixosModules.default`; it takes `self` partially applied.
- `nix/test.nix` — the nixosTest. `nix/hetzner.nix` — nixos-anywhere target (disko).
- `static/` — hand-written HTML/CSS/JS + vendored CodeMirror/highlight.js under `vendor/`.
- `examples/*.h` — dropdown examples, read at startup; label = filename sans `NN-` and `.h`.

## Non-obvious things

- **CLI shape** (verified, differs from intuition): `--safe`/`--unsafe` take a *suffix*
  argument and require `--single-file` — use `--single-file --safe ''`. Output is a
  written file (`<Module>.hs`), not stdout; diagnostics go to stderr. Always pass
  `--unique-id` or it warns.
- **The CLI needs a matching `clang` binary and `doxygen` on PATH** (not just libclang):
  clang for macro reparsing, doxygen for doc comments. As of the current pin these are
  bundled on the CLI wrapper's own PATH (with a matching `BINDGEN_EXTRA_CLANG_ARGS`), so
  this flake no longer adds them. They're in the CLI's closure, hence reachable inside
  bwrap (which binds all of `/nix/store` read-only). If a future bump drops the bundling,
  re-add version-matched `clang`+`doxygen` to `package.nix`'s `runtimeDeps`.
- **systemd hardening vs bwrap** (in `module.nix`): `RestrictAddressFamilies` must include
  `AF_NETLINK` (bwrap loopback), and never set `ProtectKernelTunables`/`ProtectControlGroups`/
  `ProtectProc`/`RestrictNamespaces`/a `SystemCallFilter` blocking clone/unshare/mount — they
  break the inner sandbox. bwrap is the real isolation boundary; the unit is defense-in-depth.
- **Coloured diagnostics via a PTY** (`runOnPty` in `Main.hs`): the CLI only emits ANSI when
  its *stderr* is a terminal (checked via `ansi-terminal`; `NO_COLOR`/`FORCE_COLOR` are ignored,
  a `dumb` `TERM` disables it). So the whole `timeout → … → CLI` chain runs on a pseudo-terminal
  (`openPseudoTerminal`) with `TERM=xterm-256color` set inside bwrap, and a reader thread drains
  the master. `app.js` parses the SGR escapes into `.ansi-*` spans. Don't wrap with `script(1)`:
  its `-- cmd` form drops empty argv (breaks `--safe ''`) and `-c` reintroduces a shell.
- **After editing `static/`, rebuild the package** — the store snapshots the dir, so a stale
  wrapped binary serves old assets (`nix run`/systemd use the store copy).
- **hs-bindgen is pinned in `flake.lock`**, not by rev in the URL. Bump with
  `nix flake update hs-bindgen`.
- `checks.integration` (the nixosTest) is defined for both Linux systems; it's
  Linux-only because it VM-tests systemd + bwrap. `nix flake check` builds only the
  current system's check (warns it "omitted incompatible systems: aarch64-linux" on
  x86), so CI on x86 never tries to build the aarch64 VM.

## User's global rules (see ~/.claude/CLAUDE.md)

Never scan `/`, `/nix/store`, or the home dir with find/grep/ls/glob — scope searches to
this project; ask for exact store paths instead. Prefer named records over tuples; keep
comments and commit messages short.
