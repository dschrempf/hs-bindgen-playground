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
    machine.wait_for_unit("hs-bindgen-playground.service")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_open_port(80)

    # A struct must generate a record with a Storable instance.
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
    bad = machine.succeed(
        "curl -sS -X POST http://localhost/api/generate "
        + "-H 'Content-Type: application/json' "
        + "-d '{\"source\":\"struct { oops\"}'"
    )
    assert '"ok":false' in bad, "bad C should report ok:false"

    # The sandbox must block filesystem reads outside the work dir.
    leak = machine.succeed(
        "curl -sS -X POST http://localhost/api/generate "
        + "-H 'Content-Type: application/json' "
        + "-d '{\"source\":\"#include \\\"/etc/passwd\\\"\"}'"
    )
    assert "root:" not in leak, "/etc/passwd contents leaked into diagnostics!"
    assert "file not found" in leak, "expected a file-not-found error"
  '';
}
