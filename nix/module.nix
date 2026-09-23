# NixOS module for the hs-bindgen playground. Applied via `nixosModules.default`,
# which partially applies `self` (the flake) so the default package resolves.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.hs-bindgen-playground;
  # Reverse-proxy site address: a real domain (→ ACME/HTTPS) or plain :80.
  siteAddr = if cfg.domain != null then cfg.domain else ":80";
in
{
  options.services.hs-bindgen-playground = {
    enable = lib.mkEnableOption "the hs-bindgen playground web service";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "hs-bindgen-playground.packages.\${system}.default";
      description = "The wrapped server package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the server listens on (behind the reverse proxy).";
    };

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "playground.example.com";
      description = ''
        Public domain. When set, caddy serves HTTPS with an ACME certificate.
        When null, caddy serves plain HTTP on port 80 (IP-only fallback).
      '';
    };

    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Contact email for Let's Encrypt (required when `domain` is set).";
    };

    maxConcurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Maximum concurrent generation jobs; excess requests get 503.";
    };

    maxInputBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536;
      description = "Maximum accepted C source size in bytes.";
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Wall-clock and CPU time limit per generation job.";
    };

    memoryBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2147483648; # 2 GiB
      description = "Address-space limit (prlimit --as) per generation job.";
    };

    verbosity = lib.mkOption {
      type = lib.types.ints.between 0 4;
      default = 2;
      description = "hs-bindgen-cli verbosity for the diagnostics panel (0–4).";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = toString (cfg.memoryBytes + 512 * 1024 * 1024);
      defaultText = lib.literalExpression "memoryBytes + 512 MiB";
      description = ''
        Physical-memory ceiling for the *whole* service (systemd `MemoryMax`,
        cgroup-enforced): every job plus the server's own request buffers. This
        is a different quantity from `memoryBytes`, which is the per-job *virtual
        address space* limit (`prlimit --as`); a job's real resident memory is
        usually far below its address-space reservation.

        The default is one job's `memoryBytes` plus 512 MiB of headroom, so a
        single heavy job that touches its full allowance still fits. It does
        *not* budget for `maxConcurrent` jobs all peaking at once — that is the
        intended backstop: a burst of memory-heavy jobs is cgroup-killed rather
        than allowed to OOM the host. Raise it if you expect several heavy jobs
        concurrently and the VM has the RAM; lower it on a tiny VM, accepting
        that one very heavy job may then be killed before it reaches its own
        `--as` limit.
      '';
    };

    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "200%";
      description = "CPU ceiling for the whole service (systemd `CPUQuota`); 100% = one core.";
    };

    tasksMax = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = "Cap on tasks/PIDs for the whole service (systemd `TasksMax`), bounding fork storms.";
    };

    readOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Kill switch: disable generation and show a banner.";
    };

    readOnlyMessage = lib.mkOption {
      type = lib.types.str;
      default = "Generation is temporarily disabled.";
      description = "Banner text shown when `readOnly` is set.";
    };

    reverseProxy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run caddy in front of the server. Turn it off on a host that already has
        its own reverse proxy or tunnel: the service then only listens on `port`,
        and `domain`/`acmeEmail`/`openFirewall` have no effect.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the firewall for the reverse proxy (80, and 443 with a domain).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain == null || cfg.acmeEmail != null;
        message = "services.hs-bindgen-playground: acmeEmail is required when domain is set.";
      }
      {
        assertion = cfg.reverseProxy.enable || cfg.domain == null;
        message = "services.hs-bindgen-playground: domain is set but reverseProxy.enable is false, so nothing would serve it.";
      }
    ];

    systemd.services.hs-bindgen-playground = {
      description = "hs-bindgen playground";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        PORT = toString cfg.port;
        PLAYGROUND_MAX_CONCURRENT = toString cfg.maxConcurrent;
        PLAYGROUND_MAX_INPUT_BYTES = toString cfg.maxInputBytes;
        PLAYGROUND_TIMEOUT_SECONDS = toString cfg.timeoutSeconds;
        PLAYGROUND_MEMORY_BYTES = toString cfg.memoryBytes;
        PLAYGROUND_VERBOSITY = toString cfg.verbosity;
        PLAYGROUND_READONLY = lib.boolToString cfg.readOnly;
        PLAYGROUND_READONLY_MESSAGE = cfg.readOnlyMessage;
      };

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";

        # Resource ceilings for the whole service — the host-level backstop that
        # holds even if the per-job prlimits inside the sandbox are evaded or
        # several jobs peak together. MemoryMax stops a large request body (or a
        # burst of them) from OOM-ing the box; TasksMax bounds fork storms.
        MemoryMax = cfg.memoryMax;
        CPUQuota = cfg.cpuQuota;
        TasksMax = cfg.tasksMax;

        # Hardening — kept compatible with bubblewrap, which needs unprivileged
        # user namespaces. Do NOT add RestrictNamespaces or a SystemCallFilter
        # that blocks clone/unshare/mount, or the inner sandbox breaks.
        DynamicUser = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        # NB: ProtectKernelTunables/ProtectControlGroups/ProtectProc are
        # deliberately NOT set — they mask parts of /proc, which stops bwrap
        # from mounting a fresh procfs in its PID namespace ("mount too
        # revealing"). bwrap is the real isolation boundary here.
        # AF_NETLINK is required: bwrap opens a NETLINK_ROUTE socket to bring up
        # loopback when it unshares the network namespace.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      };
    };

    services.caddy = lib.mkIf cfg.reverseProxy.enable {
      enable = true;
      email = lib.mkIf (cfg.acmeEmail != null) cfg.acmeEmail;
      virtualHosts.${siteAddr}.extraConfig = ''
        reverse_proxy localhost:${toString cfg.port}
      '';
    };

    networking.firewall.allowedTCPPorts =
      lib.mkIf (cfg.reverseProxy.enable && cfg.openFirewall)
        (if cfg.domain != null then [ 80 443 ] else [ 80 ]);
  };
}
