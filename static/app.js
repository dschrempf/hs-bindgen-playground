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

// --- Config / banner ------------------------------------------------------
async function loadConfig() {
  try {
    const cfg = await (await fetch("/api/config")).json();
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
    sel.appendChild(opt);
  }
  sel.addEventListener("change", () => {
    const opt = sel.selectedOptions[0];
    if (opt && opt.dataset.body !== undefined) editor.setValue(opt.dataset.body);
  });
}

// --- Generate -------------------------------------------------------------
async function generate() {
  const btn = $("generate");
  btn.disabled = true;
  btn.textContent = "Generating…";
  const bindings = $("bindings-code");
  const diagnostics = $("diagnostics-code");
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
      }),
    });
    const data = await res.json();

    command.textContent = data.command || "";
    diagnostics.textContent = data.diagnostics || "(no diagnostics)";
    diagnostics.classList.toggle("diag-error", !data.ok);

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
      diagnostics.textContent = data.error || "Server busy — try again.";
      showTab("diagnostics");
    }
  } catch (err) {
    diagnostics.textContent = "Request failed: " + err;
    diagnostics.classList.add("diag-error");
    showTab("diagnostics");
  } finally {
    btn.disabled = false;
    btn.textContent = "Generate bindings";
  }
}

$("generate").addEventListener("click", generate);

loadConfig();
loadExamples();
