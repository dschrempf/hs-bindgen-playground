# hs-bindgen-playground — plan

> **Done (2026-07-22).** Everything in this plan and GitHub issue #1 is
> implemented and verified (`nix flake check` passes end-to-end). The one
> unresolved open item — bumping/tuning trace verbosity for the demo — is
> carried over to `todo.org` (§Verbosity), so nothing is duplicated here.

A small public web service for the MuniHac talk: paste a C header, click
**Generate bindings**, get back the generated Haskell module (plus the exact CLI
command and hs-bindgen's diagnostics/traces). Lives in its own repo, deployed
with Nix, pinning this repo as a flake input.

## Decisions (locked)

| Question | Decision |
|---|---|
| Access | Fully public URL, no auth. Security is handled by sandboxing, not gating. |
| Servers | Laptop + personal server are NixOS. Hetzner: rent any Cloud VM, convert with `nixos-anywhere`. |
| TLS / domain | **Configurable** — set shortly before the talk via a module option; ACME/caddy turns on once a domain is known. Plain HTTP-over-IP as fallback. |
| hs-bindgen version | **Pinned** as a flake input (specific rev), not tracking `main`. |
| Server stack | Haskell **scotty** + warp. |
| Repo | Personal GitHub for now (`<you>/hs-bindgen-playground`), later moves to well-typed. |
| UI features | Examples dropdown, C-standard/safe-unsafe options, syntax highlighting, output tabs for bindings + diagnostics/traces + exact CLI command, copy-to-clipboard. |

## Core architecture

**Shell out to the Nix-built `hs-bindgen-cli`; do not link the library.**
The process boundary is the sandbox unit, it decouples us from the churny
`hs-bindgen:internal` API, and the Nix wrapper already bakes in
`BINDGEN_EXTRA_CLANG_ARGS` + `BINDGEN_BUILTIN_INCLUDE_DIR=disable`, so clang
headers work with no system clang.

Per-request flow:

1. Enforce input size cap (e.g. 64 KiB) and a concurrency gate (bounded `QSem`,
   reject with 503 when full — a room of people clicking at once must not OOM
   the box).
2. Fresh temp dir; write `input.h`.
3. Run the CLI **inside a sandbox** (see below):
   ```
   hs-bindgen-cli preprocess \
     --single-file --safe \
     --unique-id playground.hs-bindgen \
     --hs-output-dir $work/out \
     --module Demo \
     --create-output-dirs --overwrite-files \
     [--clang-option=-std=c11] \
     input.h
   ```
   (`--safe`/`--unsafe` and `-std` come from the UI options. The CLI has no
   stdout mode, so we read the single written file back.)
4. Read `$work/out/Demo.hs`; capture the process's stderr (that's where
   hs-bindgen's trace/diagnostic messages go).
5. Return JSON `{ ok, bindings, command, diagnostics, exitCode }`.
6. Delete the temp dir.

## Sandboxing (the important part)

Threat model: attacker-controlled C fed to libclang on a public box. Clang does
**not** execute the C, so there is no direct RCE from parsing — the real risks
are (a) **info disclosure** (`#include "/etc/…"` etc.; clang echoes offending
file lines in error messages), (b) **resource exhaustion** (huge/pathological
input), and (c) defense-in-depth against anything clang might touch.

Layered mitigation, per request:

- **Filesystem confinement — `bubblewrap` (bwrap).** Read-only bind `/nix/store`
  only; a fresh tmpfs `/tmp`; bind the per-request work dir writable; `--dev`,
  `--proc`; `--unshare-all` (incl. `--unshare-net`); `--clearenv` +
  re-set `PATH`/`TMPDIR`; `--die-with-parent`; `--new-session`. This closes the
  info-disclosure hole: no `/etc`, `/home`, or arbitrary paths are visible, so
  `#include`-based file reads can't leak anything.
- **Wall-clock timeout — `timeout --signal=KILL 10s`** (tune).
- **Resource caps — `prlimit`**: `--as` (address space), `--cpu`, `--fsize`,
  `--nofile`. Optionally also cap output file size / truncate the returned
  bindings and diagnostics to a max length.
- **Outer systemd unit** hardened *compatibly with bwrap*: `DynamicUser=yes`,
  `ProtectHome=yes`, `ProtectSystem=strict`, `PrivateTmp=yes`,
  `NoNewPrivileges=yes`, restricted address families, etc. **Caveat:** bwrap
  needs unprivileged user namespaces, so do **not** set `RestrictNamespaces=yes`
  or a `SystemCallFilter` that blocks `clone`/`unshare`/`mount`. (NixOS enables
  unprivileged userns by default.)

Alternative considered: `systemd-run --scope -p MemoryMax=… -p RuntimeMaxSec=…
-p PrivateNetwork=yes …` per job. Cleaner cgroup limits, but spawning transient
units from a `DynamicUser` service drags in polkit/bus-permission complexity.
Chosen bwrap+prlimit+timeout as the self-contained primary; `systemd-run` noted
as a future hardening option.

## Server (scotty)

Endpoints:

- `GET /` → static `index.html`.
- `GET /static/*` → vendored JS/CSS/assets.
- `GET /api/examples` → the curated example headers (name + body) for the
  dropdown.
- `POST /api/generate` → `{ source, std, safe, module }` → the JSON result above.

Notes:
- **Vendor the frontend JS/CSS locally** (CodeMirror for the C editor +
  highlight.js for the Haskell output, or equivalent). Do **not** rely on a CDN
  during the talk.
- A **kill switch / read-only banner** flag (module option / env) to disable
  `/api/generate` and show a message, in case something goes sideways live.
- Log minimally; do not log input bodies by default (privacy + noise).

## UI

- **Left:** C editor (CodeMirror, C mode) with an **examples dropdown** above it.
- **Options row:** C standard select (`c89/c99/c11/c17/c23`), safe/unsafe toggle,
  optional module name (default `Demo`).
- **Generate bindings** button.
- **Right:** tabbed panel —
  - *Bindings* (Haskell, syntax-highlighted, copy-to-clipboard),
  - *Diagnostics / traces* (CLI stderr),
  - *Command* (the exact `hs-bindgen-cli …` line that ran — educational for the
    talk: "look, it's just this").

### Curated examples (~5–6)

Pick ones that show off features and are guaranteed to work live: a simple
struct; an enum; a function prototype; a typedef; a `#define` constant macro; a
header using `<stdint.h>` fixed-width types. Baked into the package (a dir in the
store), read at startup.

## Repo layout

```
flake.nix                 # inputs: hs-bindgen (pinned), nixpkgs (follows hs-bindgen)
flake.lock
cabal.project
hs-bindgen-playground.cabal
app/Main.hs               # scotty server (~200 lines: static + shell-out wrapper)
static/index.html
static/app.js
static/style.css
static/vendor/…           # CodeMirror, highlight.js (vendored)
examples/*.h              # curated example headers
nix/
  package.nix             # server derivation, wrapProgram to put
                          #   hs-bindgen-cli + bubblewrap + coreutils(timeout)
                          #   + util-linux(prlimit) on PATH
  module.nix              # NixOS module (hardened systemd service + optional caddy/ACME)
  hetzner.nix             # example host: disko + nixos-anywhere target
README.md
```

## Nix design

**flake inputs**
```nix
inputs.hs-bindgen.url = "github:well-typed/hs-bindgen?rev=<PINNED_REV>";
inputs.nixpkgs.follows = "hs-bindgen/nixpkgs";   # same nixpkgs → no skew, single eval
```
Get the CLI from `hs-bindgen.packages.${system}.hs-bindgen-cli` (that repo's
`default` package; plain `haskellPackages`, no haskell.nix).

**outputs**
- `packages.default` — the wrapped server binary.
- `nixosModules.default` — the service module. Options: `enable`, `port`,
  `domain` (nullable → HTTP-only when null), `acmeEmail`, `maxConcurrent`,
  `maxInputBytes`, `timeoutSeconds`, `memoryLimit`, `readOnly` (kill switch),
  `package`, `hsBindgenCli`.
- `apps.default` / `packages.default` — `nix run` for local dev.
- `checks.<system>.integration` — a **nixosTest** VM that boots the module,
  `POST`s a small header to `/api/generate`, and asserts real bindings come
  back. Doubles as the local test story and CI.
- `nixosConfigurations.hetzner` — example host importing the module + `disko`,
  the `nixos-anywhere` target.

## Local testing (laptop, NixOS)

- `nix run .#` → server on `localhost:PORT`, poke it in a browser.
- `nix build .#checks.<system>.integration` → end-to-end VM test of the module.
- `nixos-rebuild build-vm --flake .#hetzner` → boot the full host config in a
  local VM (dummy domain / self-signed) to rehearse the real deployment.

## Deployment

**Personal server (NixOS, prolonged):** import `nixosModules.default` into the
existing config, set options (port, examples, limits, and `domain` once known),
`nixos-rebuild switch`. Reachable long-term for demos.

**Hetzner (talk duration):**
1. Rent any Hetzner Cloud VM (no NixOS image needed).
2. From the laptop: `nixos-anywhere --flake .#hetzner root@IP` — installs NixOS
   with the module baked in.
3. Firewall opens 80/443 only.
4. Once the domain is pointed at the IP: set the `domain`/`acmeEmail` options and
   redeploy → caddy provisions Let's Encrypt TLS. (If no domain in time: serve
   plain HTTP over the IP.)
5. Tear the machine down after the talk.

## Open items / to tune during implementation

- Exact bwrap invocation (which store paths / `--dev` / `--proc` are actually
  needed by the wrapped CLI at runtime); verify a trivial header generates
  inside the sandbox before adding restrictions.
- Whether hs-bindgen's default trace verbosity gives a useful "diagnostics"
  panel, or we bump verbosity for the demo.
- Output truncation limits (bindings + diagnostics) for pathological inputs.
- `--unique-id` value and whether to expose module name in the UI or fix it.
