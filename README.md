# hs-bindgen-playground

A small public web service: paste a C header, click **Generate bindings**, and
get back the Haskell module produced by
[hs-bindgen](https://github.com/well-typed/hs-bindgen) — plus the exact CLI
command that ran and hs-bindgen's diagnostics.

Built for a MuniHac talk. It shells out to the Nix-built `hs-bindgen-cli`
(pinned as a flake input) inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox, so it is safe to expose publicly.

## How it works

Per request the server:

1. Enforces an input-size cap and a bounded concurrency gate (503 when full).
2. Writes the source to a fresh temp dir as `input.h`.
3. Runs the CLI inside a layered sandbox:
   `timeout --signal=KILL` → `prlimit` (address space / CPU / file size / fds)
   → `bwrap` (`--unshare-all`, `--clearenv`, read-only `/nix/store`, private
   `/tmp`, work dir bound at `/work`).
4. Reads back `out/<Module>.hs` and captures stderr (hs-bindgen's traces).
5. Returns `{ ok, bindings, command, diagnostics, exitCode }`; deletes the temp dir.

The sandbox closes the main risk of feeding attacker-controlled C to libclang —
information disclosure via `#include`. With no `/etc` or `/home` visible,
`#include "/etc/passwd"` simply fails with *file not found*.

## Develop

```sh
nix develop            # ghc, cabal, hs-bindgen-cli, bwrap, clang, doxygen, …
cabal run              # or: nix run .#   (server on http://localhost:3000)
```

`nix run .#` serves the wrapped binary with all runtime tools on `PATH`.

### Configuration (environment)

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `3000` | Listen port |
| `PLAYGROUND_MAX_CONCURRENT` | `4` | Concurrent generation jobs |
| `PLAYGROUND_MAX_INPUT_BYTES` | `65536` | Max C source size |
| `PLAYGROUND_TIMEOUT_SECONDS` | `10` | Wall-clock/CPU limit per job |
| `PLAYGROUND_MEMORY_BYTES` | `2147483648` | Address-space cap per job |
| `PLAYGROUND_VERBOSITY` | `2` | hs-bindgen-cli verbosity (0–4) |
| `PLAYGROUND_READONLY` | `false` | Kill switch: disable generation |
| `PLAYGROUND_READONLY_MESSAGE` | — | Banner text when read-only |

## Test

```sh
nix build .#checks.x86_64-linux.integration   # boots the module in a VM,
                                               # POSTs a header, asserts bindings
```

## Deploy

### Existing NixOS host

Import the module and set options:

```nix
{
  imports = [ hs-bindgen-playground.nixosModules.default ];
  services.hs-bindgen-playground = {
    enable = true;
    domain = "playground.example.com";   # omit for plain HTTP over IP
    acmeEmail = "you@example.com";        # required when domain is set
  };
}
```

With a `domain`, caddy provisions Let's Encrypt TLS automatically. The systemd
unit is hardened (`DynamicUser`, `ProtectSystem=strict`, …) but deliberately
leaves user namespaces available, since bubblewrap needs them.

On a host that already terminates TLS — its own nginx, or a Cloudflare tunnel —
set `reverseProxy.enable = false` and point that proxy at `port`; caddy would
otherwise fight the existing one for 80/443:

```nix
services.hs-bindgen-playground = {
  enable = true;
  reverseProxy.enable = false;
  port = 3000;
};
```

### Fresh Hetzner Cloud VM (talk duration)

Rent any Cloud VM, then from your laptop (see `nix/hetzner.nix` — fill in the
SSH key and, once DNS is ready, the domain):

```sh
nixos-anywhere --flake .#hetzner root@<IP>
```

## Layout

```
app/Main.hs        scotty server + sandboxed shell-out
static/            index.html, app.js, style.css, vendored CodeMirror + highlight.js
examples/*.h       curated example headers (dropdown)
nix/package.nix    wrapped server derivation
nix/module.nix     NixOS module (hardened service + optional caddy/ACME)
nix/test.nix       nixosTest integration check
nix/hetzner.nix    nixos-anywhere target (disko)
```
