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
  `reverseProxy.enable = false` drops caddy for hosts that terminate TLS themselves.
- `nix/test.nix` — the nixosTest. `nix/hetzner.nix` — nixos-anywhere target (disko).
- `static/` — hand-written HTML/CSS/JS + vendored CodeMirror/highlight.js under `vendor/`.
- `examples/*.h` — dropdown examples, read at startup; label = filename sans `NN-` and `.h`.
  An optional sibling `NN-name.opts` fills the additional-options field on selection
  (the talk examples use it for `--omit-field-prefixes`).

## Non-obvious things

- **CLI shape** (verified, differs from intuition): `--safe`/`--unsafe` take a *suffix*
  argument and require `--single-file` — use `--single-file --safe ''`. Output is a
  written file (`<Module>.hs`), not stdout; diagnostics go to stderr. Always pass
  `--unique-id` or it warns.
- **The CLI needs a matching `clang` binary and `doxygen` on PATH** (not just libclang):
  clang for macro reparsing, doxygen for doc comments. As of the current pin these are
  bundled on the CLI wrapper's own PATH (with a matching `BINDGEN_EXTRA_CLANG_ARGS`), so
  this flake no longer adds them. They're in the CLI's closure, hence bound inside bwrap.
  If a future bump drops the bundling, re-add version-matched `clang`+`doxygen` to
  `package.nix`'s `runtimeDeps`.
- **The sandbox binds only `runtimeDeps`' closure, not all of `/nix/store`** (~78 paths).
  `package.nix` computes it with `closureInfo` and points `PLAYGROUND_STORE_PATHS` at the
  resulting `store-paths` file; the dev shell sets the same variable so `cabal run` matches.
  A runtime tool absent from `runtimeDeps` is therefore *missing inside the sandbox* even
  though it's on PATH — symptom is a "file not found"/exec failure, not a store permission
  error. Unset variable falls back to binding the whole store.
- **Additional options are an allowlist** (`allowedOpts` in `Main.hs`), not a passthrough:
  known `preprocess` flags plus their argument count. Nothing that names a file, reaches
  clang (`--clang-option*`, `-I`), or duplicates a flag `cliArgs` fixes. Add new flags
  there; the UI placeholder in `index.html` is the only other place that mentions them.
- **systemd hardening vs bwrap** (in `module.nix`): `RestrictAddressFamilies` must include
  `AF_NETLINK` (bwrap loopback), and never set `ProtectKernelTunables`/`ProtectControlGroups`/
  `ProtectProc`/`RestrictNamespaces`/a `SystemCallFilter` blocking clone/unshare/mount — they
  break the inner sandbox. bwrap is the real isolation boundary; the unit is defense-in-depth.
- **Coloured diagnostics via `--color always`**: the CLI's `--color WHEN` global option
  (`always`/`auto`/`never`, from hs-bindgen PR #2167) forces ANSI escapes regardless of
  whether stderr is a terminal, so we just capture stderr off a plain pipe (`runCapture` in
  `Main.hs`) and `app.js` parses the SGR escapes into `.ansi-*` spans. This replaced an
  earlier PTY hack (`ansi-terminal` only emits colour on a tty).
- **Never give the CLI a closed stdout** (`NoStream` in `runCapture`): with fd 1 closed it
  hangs on its error path, so every failed generation stalls until the timeout kills it.
  `/dev/null` is fine; see the comment there.
- **The version shown in the header comes from Nix, not from the code**: `flake.nix`
  computes `self.shortRev`/`dirtyShortRev` and the pinned hs-bindgen's rev, `package.nix`
  turns them into `versionEnv` (`PLAYGROUND_VERSION`, `PLAYGROUND_REVISION`,
  `PLAYGROUND_HS_BINDGEN_*`) on the wrapper, and the dev shell sets the same attrset.
  Versions themselves are the derivations' (`server.version`, `hsBindgenCli.version`), so
  the cabal files stay the single source. Unset → "dev"; a dirty rev is shown unlinked.
- **After editing `static/`, rebuild the package** — the store snapshots the dir, so a stale
  wrapped binary serves old assets (`nix run`/systemd use the store copy).
- **Static assets carry an explicit `Cache-Control`** (`cachePolicyFor` in `Main.hs`):
  `no-cache` for the HTML and our own JS/CSS, a year of `immutable` for `static/vendor/**`.
  Store mtimes are 1970, so without it browsers cache heuristically forever and a CDN
  invents its own TTL — Cloudflare served a pre-deploy `app.js` for hours in front of
  Blaubaer. The vendor exemption is an invariant: replace a vendored bundle under a new
  file name, never in place.
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
