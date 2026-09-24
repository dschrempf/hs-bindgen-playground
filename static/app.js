"use strict";

const editor = CodeMirror.fromTextArea(document.getElementById("source"), {
  mode: "text/x-csrc",
  lineNumbers: true,
  theme: "default",
  matchBrackets: true,
});

const $ = (id) => document.getElementById(id);

// --- Tabs -----------------------------------------------------------------
document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    const name = tab.dataset.tab;
    document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t === tab));
    document.querySelectorAll(".tab-panel").forEach((p) =>
      p.classList.toggle("active", p.dataset.panel === name));
  });
});

function showTab(name) {
  document.querySelector(`.tab[data-tab="${name}"]`).click();
}

// --- Diagnostics colouring ------------------------------------------------
// The server runs hs-bindgen-cli on a pseudo-terminal so it emits its usual
// ANSI-coloured diagnostics; we parse the SGR escapes into styled spans. Only
// foreground colour and bold are used (`.ansi-*` classes in style.css).
function renderDiagnostics(text) {
  const code = $("diagnostics-code");
  const frag = document.createDocumentFragment();
  const re = /\x1b\[([0-9;]*)m/g;
  let last = 0, fg = null, bold = false, m;
  const emit = (s) => {
    if (!s) return;
    const span = document.createElement("span");
    const cls = [fg, bold ? "ansi-bold" : null].filter(Boolean);
    if (cls.length) span.className = cls.join(" ");
    span.textContent = s;
    frag.appendChild(span);
  };
  while ((m = re.exec(text)) !== null) {
    emit(text.slice(last, m.index));
    last = re.lastIndex;
    for (const p of (m[1] || "0").split(";")) {
      const n = parseInt(p || "0", 10);
      if (n === 0) { fg = null; bold = false; }
      else if (n === 1) bold = true;
      else if (n === 22) bold = false;
      else if (n === 39) fg = null;
      else if ((n >= 30 && n <= 37) || (n >= 90 && n <= 97)) fg = "ansi-" + n;
    }
  }
  emit(text.slice(last));
  code.replaceChildren(frag);
}

// Show a plain (non-ANSI) message, e.g. a client-side error, tinted as an error.
function showDiagnosticsError(text) {
  renderDiagnostics("\x1b[91;1m" + text + "\x1b[m");
}

// --- Copy buttons ---------------------------------------------------------
document.querySelectorAll(".copy").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const text = $(btn.dataset.copy).textContent;
    await navigator.clipboard.writeText(text);
    const old = btn.textContent;
    btn.textContent = "Copied!";
    setTimeout(() => (btn.textContent = old), 1200);
  });
});

// --- Versions -------------------------------------------------------------
// One line per component: "name version (rev)", the revision linked to its
// commit when the build came from a clean tree (server sends no commitUrl
// otherwise).
function renderVersions(versions) {
  const box = $("versions");
  box.replaceChildren();
  for (const v of versions || []) {
    const line = document.createElement("div");
    line.append(`${v.name} ${v.version}`);
    if (v.revision) {
      const link = document.createElement(v.commitUrl ? "a" : "span");
      link.textContent = v.revision;
      if (v.commitUrl) {
        link.href = v.commitUrl;
        link.rel = "noopener";
      } else {
        link.className = "dirty";
        link.title = "built from a tree with uncommitted changes";
      }
      line.append(" (", link, ")");
    }
    box.appendChild(line);
  }
}

// --- Config / banner ------------------------------------------------------
async function loadConfig() {
  try {
    const cfg = await (await fetch("/api/config")).json();
    renderVersions(cfg.versions);
    if (cfg.readOnly) {
      const banner = $("banner");
      banner.textContent = cfg.message || "Generation is temporarily disabled.";
      banner.hidden = false;
      $("generate").disabled = true;
    }
  } catch (_) { /* non-fatal */ }
}

// --- Examples -------------------------------------------------------------
async function loadExamples() {
  const examples = await (await fetch("/api/examples")).json();
  const sel = $("examples");
  for (const ex of examples) {
    const opt = document.createElement("option");
    opt.value = ex.name;
    opt.textContent = ex.name;
    opt.dataset.body = ex.body;
    opt.dataset.options = ex.options;
    sel.appendChild(opt);
  }
  sel.addEventListener("change", () => {
    const opt = sel.selectedOptions[0];
    if (opt && opt.dataset.body !== undefined) {
      editor.setValue(opt.dataset.body);
      $("options").value = opt.dataset.options;
    }
  });
}

// --- Generate -------------------------------------------------------------
async function generate() {
  const btn = $("generate");
  btn.disabled = true;
  btn.textContent = "Generating…";
  const bindings = $("bindings-code");
  const command = $("command-code");
  try {
    const res = await fetch("/api/generate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        source: editor.getValue(),
        std: $("std").value,
        safe: $("safe").value === "safe",
        module: $("module").value.trim() || "Demo",
        verbosity: parseInt($("verbosity").value, 10),
        macroWarnings: $("macroWarnings").checked,
        options: $("options").value,
      }),
    });
    const data = await res.json();

    command.textContent = data.command || "";
    renderDiagnostics(data.diagnostics || "(no diagnostics)");

    if (data.ok) {
      bindings.textContent = data.bindings || "";
      bindings.className = "language-haskell";
      // For reasons of performance, highlight.js has a safeguard to avoid
      // elements being highlighted multiple times. However, in our case we need
      // to highlight again when we generate the code again.
      bindings.removeAttribute('data-highlighted');
      hljs.highlightElement(bindings);
      showTab("bindings");
    } else {
      bindings.textContent = "";
      showTab("diagnostics");
    }
    if (res.status === 503 && !data.diagnostics) {
      showDiagnosticsError(data.error || "Server busy — try again.");
      showTab("diagnostics");
    }
  } catch (err) {
    showDiagnosticsError("Request failed: " + err);
    showTab("diagnostics");
  } finally {
    btn.disabled = false;
    btn.textContent = "Generate bindings";
  }
}

$("generate").addEventListener("click", generate);

loadConfig();
loadExamples();
