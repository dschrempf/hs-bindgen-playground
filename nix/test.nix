# Integration test: boot the module in a VM, POST a header through caddy,
# and assert real Haskell bindings come back (exercises the bwrap sandbox too).
{ pkgs, module }:

pkgs.testers.nixosTest {
  name = "hs-bindgen-playground";

  nodes.machine = { ... }: {
    imports = [ module ];
    services.hs-bindgen-playground = {
      enable = true;
      # domain = null → caddy serves plain HTTP on :80.
    };
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 8192;
  };

  testScript = ''
    import base64, json

    def post(payload):
        b64 = base64.b64encode(json.dumps(payload).encode()).decode()
        machine.succeed(f"echo {b64} | base64 -d > /tmp/req.json")
        return machine.succeed(
            "curl -sS -X POST http://localhost/api/generate "
            + "-H 'Content-Type: application/json' --data @/tmp/req.json"
        )

    machine.wait_for_unit("hs-bindgen-playground.service")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_open_port(80)

    # The header's version line comes from /api/config; the same strings are
    # logged at startup. "dev" means the wrapper failed to set them.
    print("--- running check: /api/config reports versions ---")
    cfg = json.loads(machine.succeed("curl -sS http://localhost/api/config"))
    print(cfg)
    versions = {v["name"]: v for v in cfg["versions"]}
    assert set(versions) == {"playground", "hs-bindgen"}, f"unexpected versions: {cfg}"
    assert all(v["version"] != "dev" for v in versions.values()), f"no version set: {cfg}"
    journal = machine.succeed("journalctl -u hs-bindgen-playground.service --no-pager")
    for v in versions.values():
        assert f"{v['name']} {v['version']}" in journal, f"{v['name']} not in the journal"

    # Every shipped example must generate bindings — the exact set the UI serves.
    examples = json.loads(machine.succeed("curl -sS http://localhost/api/examples"))
    assert examples, "server served no examples"
    for ex in examples:
        print(f"--- running example {ex['name']!r} ---")
        out = post({"source": ex["body"], "module": "Example"})
        assert json.loads(out).get("ok") is True, f"example {ex['name']!r} failed: {out}"
    print(f"generated bindings for {len(examples)} examples")

    # A struct must generate a record with a Storable instance.
    print("--- running check: struct generates record + Storable ---")
    out = machine.succeed(
        "curl -sS -X POST http://localhost/api/generate "
        + "-H 'Content-Type: application/json' "
        + "-d '{\"source\":\"struct Point { int x; int y; };\",\"module\":\"Demo\"}'"
    )
    print(out)
    assert '"ok":true' in out, "generation did not succeed"
    assert "data Point" in out, "expected record for struct Point"
    assert "Storable" in out, "expected a Storable instance"

    # Bad C must fail cleanly, not crash the service.
    print("--- running check: bad C fails cleanly ---")
    bad = machine.succeed(
        "curl -sS -X POST http://localhost/api/generate "
        + "-H 'Content-Type: application/json' "
        + "-d '{\"source\":\"struct { oops\"}'"
    )
    print(bad)
    assert '"ok":false' in bad, "bad C should report ok:false"

    # The sandbox must block filesystem reads outside the work dir.
    print("--- running check: sandbox blocks /etc/passwd read ---")
    leak = machine.succeed(
        "curl -sS -X POST http://localhost/api/generate "
        + "-H 'Content-Type: application/json' "
        + "-d '{\"source\":\"#include \\\"/etc/passwd\\\"\"}'"
    )
    print(leak)
    assert "root:" not in leak, "/etc/passwd contents leaked into diagnostics!"
    assert "file not found" in leak, "expected a file-not-found error"

    # Only the CLI's own closure is bound, so the system closure is unreachable.
    print("--- running check: sandbox binds only the CLI closure ---")
    system = machine.succeed("readlink -f /run/current-system").strip()
    leak = post({"source": f'#include "{system}/activate"'})
    print(leak)
    assert "file not found" in leak, f"{system}/activate was readable in the sandbox!"

    # The additional-options field only accepts allowlisted preprocess flags.
    print("--- running check: additional options are allowlisted ---")
    ok = post({"source": "struct Point { int x; };", "options": "--select-all"})
    assert '"ok":true' in ok, f"allowlisted option rejected: {ok}"
    denied = post({"source": "int x;", "options": "--clang-option=-I/etc"})
    print(denied)
    assert "Option not allowed" in denied, "clang passthrough should be rejected"
  '';
}
