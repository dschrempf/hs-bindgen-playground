# Integration test: boot the module in a VM, POST a header through caddy,
# and assert real Haskell bindings come back (exercises the bwrap sandbox too).
{ pkgs, module }:

let
  # Stands in for Plausible's Events API: appends each event, with the headers
  # the server forwards, to `plausibleLog`.
  plausiblePort = 8125;
  plausibleLog = "/tmp/plausible.jsonl";
  plausibleMock = pkgs.writeText "plausible-mock.py" ''
    import http.server, json

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            event = {
                "path": self.path,
                "userAgent": self.headers.get("User-Agent"),
                "forwardedFor": self.headers.get("X-Forwarded-For"),
                "body": json.loads(body),
            }
            with open("${plausibleLog}", "a") as f:
                f.write(json.dumps(event) + "\n")
            self.send_response(202)
            self.end_headers()
            self.wfile.write(b"{}")

    http.server.HTTPServer(("127.0.0.1", ${toString plausiblePort}), Handler).serve_forever()
  '';
in
pkgs.testers.nixosTest {
  name = "hs-bindgen-playground";

  nodes.machine = { ... }: {
    imports = [ module ];
    services.hs-bindgen-playground = {
      enable = true;
      # domain = null → caddy serves plain HTTP on :80.
      plausible = {
        enable = true;
        domain = "playground.test";
        endpoint = "http://127.0.0.1:${toString plausiblePort}/api/event";
      };
    };
    systemd.services.plausible-mock = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3.interpreter} ${plausibleMock}";
    };
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 8192;
  };

  testScript = { nodes, ... }: ''
    import base64, html.parser, json

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
    machine.wait_for_open_port(${toString plausiblePort})

    # The header's version line comes from /api/config; the same strings are
    # logged at startup. "dev" means the wrapper failed to set them.
    print("--- running check: /api/config reports versions ---")
    cfg = json.loads(machine.succeed("curl -sS http://localhost/api/config"))
    print(cfg)
    versions = {v["name"]: v for v in cfg["versions"]}
    assert set(versions) == {"playground", "hs-bindgen"}, f"unexpected versions: {cfg}"
    assert all(v["version"] != "dev" for v in versions.values()), f"no version set: {cfg}"
    assert cfg["readOnly"] is None, f"read-only while generation is enabled: {cfg}"
    journal = machine.succeed("journalctl -u hs-bindgen-playground.service --no-pager")
    for v in versions.values():
        assert f"{v['name']} {v['version']}" in journal, f"{v['name']} not in the journal"

    # Every shipped example must generate bindings — the exact set the UI serves,
    # with the options it fills in: the example's own, else the field's default.
    class OptionsDefault(html.parser.HTMLParser):
        value: str | None = None
        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == "input" and attrs.get("id") == "options":
                self.value = attrs.get("value", "")
    page = OptionsDefault()
    page.feed(machine.succeed("curl -sS http://localhost/"))
    assert page.value is not None, "page has no options field"
    examples = json.loads(machine.succeed("curl -sS http://localhost/api/examples"))
    assert examples, "server served no examples"
    for ex in examples:
        opts = page.value if ex["options"] is None else ex["options"]
        print(f"--- running example {ex['name']!r} with options {opts!r} ---")
        res = json.loads(post({"source": ex["body"], "module": "Example", "options": opts}))
        assert res.get("ok") is True, f"example {ex['name']!r} failed: {res}"
        assert opts in res["command"], f"options {opts!r} not passed: {res['command']}"
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

    # The Help tab describes the allowlist from the CLI's own help; the server
    # warns at startup about an allowlisted flag that help lacks (a bump).
    print("--- running check: /api/help describes the allowlist ---")
    help = json.loads(machine.succeed("curl -sS http://localhost/api/help"))
    assert any(e["usage"] == "--hash-define NAME VALUE" for e in help), f"unexpected help: {help}"
    journal = machine.succeed("journalctl -u hs-bindgen-playground.service --no-pager")
    assert "warning: allowlisted" not in journal, "allowlist out of sync with `preprocess --help`"

    # Every request above is recorded, and nothing a visitor typed is.
    print("--- running check: usage statistics ---")
    stats_file = "${nodes.machine.services.hs-bindgen-playground.stats.file}"
    raw = machine.succeed(f"cat {stats_file}")
    events = [json.loads(l) for l in raw.splitlines()]
    kinds = [e["event"] for e in events]
    assert kinds.count("started") == 1, f"unexpected starts: {kinds}"
    assert kinds.count("pageView") == 1, f"unexpected page views: {kinds}"
    generated = [e for e in events if e["event"] == "generate"]
    assert len(generated) == len(examples) + 6, f"unexpected generate events: {generated}"
    assert [e["example"] for e in generated[:len(examples)]] == [ex["name"] for ex in examples]
    assert generated[len(examples)]["example"] is None, "custom header counted as an example"
    assert generated[-1]["result"] == "invalid", f"rejected options not recorded: {generated[-1]}"
    secrets = ["Point", "passwd", "clang-option", system]
    for secret in secrets:
        assert secret not in raw, f"{secret!r} from a request leaked into the statistics"

    # Plausible gets every request above plus this page view, in order, with
    # the address caddy saw rather than the one the client claims.
    print("--- running check: Plausible events ---")
    machine.succeed(
        "curl -sS -o /dev/null -A 'Mozilla/5.0 (test)' -e https://example.org/ "
        + "-H 'X-Forwarded-For: 203.0.113.7' http://localhost/"
    )
    expected = len(events) - kinds.count("started") + 1
    machine.wait_until_succeeds(f"test $(wc -l < ${plausibleLog}) -eq {expected}")
    sent_raw = machine.succeed("cat ${plausibleLog}")
    sent = [json.loads(l) for l in sent_raw.splitlines()]
    print(sent[-1])
    names = [s["body"]["name"] for s in sent]
    assert names == ["pageview"] + ["Generate"] * len(generated) + ["pageview"], f"unexpected events: {names}"
    assert all(s["path"] == "/api/event" for s in sent), "wrong endpoint path"
    assert all(s["body"]["domain"] == "playground.test" for s in sent), "wrong site domain"
    addresses = {s["forwardedFor"] for s in sent}
    assert addresses <= {"127.0.0.1", "::1"}, f"unexpected visitor addresses: {addresses}"
    assert sent[-1]["userAgent"] == "Mozilla/5.0 (test)", f"user agent not forwarded: {sent[-1]}"
    assert sent[-1]["body"]["referrer"] == "https://example.org/", f"referrer not forwarded: {sent[-1]}"
    props = [s["body"]["props"] for s in sent if s["body"]["name"] == "Generate"]
    assert [p.get("example") for p in props[:len(examples)]] == [ex["name"] for ex in examples]
    assert props[-1] == {"result": "invalid"}, f"unexpected props: {props[-1]}"
    assert all("inputBytes" not in p and "durationMs" not in p for p in props), "numbers sent"
    for secret in secrets:
        assert secret not in sent_raw, f"{secret!r} from a request leaked to Plausible"
    journal = machine.succeed("journalctl -u hs-bindgen-playground.service --no-pager")
    assert "Plausible" not in journal, "a usage event failed to reach Plausible"
  '';
}
