// Popup UI.
//
// Two views, toggled by the gear / back-arrow icons:
//   * Save (default): one big "Save current page" button + status
//   * Settings: server URL + API token form
//
// On open, if no server URL is configured, the settings view is shown
// first so the user lands on the only thing they can do. Once a URL
// exists, the save view is the default surface.
//
// Token is stored in the platform Keychain via a setToken native message;
// it never persists in browser.storage.local.
import { ensureLiveRegions, announceStatus, announceAlert } from "../shared/a11y";

declare const browser: typeof chrome;

document.addEventListener("DOMContentLoaded", () => {
  ensureLiveRegions();

  const viewSave = document.getElementById("view-save") as HTMLElement;
  const viewSettings = document.getElementById("view-settings") as HTMLElement;
  const openSettingsBtn = document.getElementById("open-settings") as HTMLButtonElement;
  const closeSettingsBtn = document.getElementById("close-settings") as HTMLButtonElement;

  const brandHost = document.getElementById("brand-host") as HTMLElement;
  const saveHint = document.getElementById("save-hint") as HTMLElement;
  const triggerSaveBtn = document.getElementById("trigger-save") as HTMLButtonElement;
  const statusEl = document.getElementById("status") as HTMLParagraphElement;

  const urlInput = document.getElementById("server-url") as HTMLInputElement;
  const tokenInput = document.getElementById("api-token") as HTMLInputElement;
  const saveConfigBtn = document.getElementById("save-config") as HTMLButtonElement;
  const settingsStatusEl = document.getElementById("settings-status") as HTMLParagraphElement;

  function showView(name: "save" | "settings") {
    viewSave.classList.toggle("active", name === "save");
    viewSettings.classList.toggle("active", name === "settings");
  }

  openSettingsBtn.addEventListener("click", () => showView("settings"));
  closeSettingsBtn.addEventListener("click", () => showView("save"));

  // Boot: load configured state, decide which view to show.
  void browser.storage.local.get(["serverURL", "tokenHost"]).then((stored) => {
    const existing = (stored as Record<string, unknown>).serverURL;
    const tokenHost = (stored as Record<string, unknown>).tokenHost;

    if (typeof existing === "string" && existing) {
      urlInput.value = existing;
      try {
        brandHost.textContent = new URL(existing).host;
      } catch {
        brandHost.textContent = existing;
      }
      triggerSaveBtn.disabled = false;
      saveHint.hidden = true;
    } else {
      brandHost.textContent = "Not configured";
      triggerSaveBtn.disabled = true;
      saveHint.hidden = false;
      // First-run: jump straight to settings.
      showView("settings");
    }

    if (tokenHost) {
      tokenInput.placeholder = "Token saved. Paste a new one to replace.";
    }
  });

  saveConfigBtn.addEventListener("click", async () => {
    const raw = urlInput.value.trim();
    if (!raw) {
      setSettingsStatus("Enter a server URL.", "err");
      return;
    }
    let url: URL;
    try {
      url = new URL(raw);
    } catch {
      setSettingsStatus("Not a valid URL.", "err");
      return;
    }
    if (url.protocol !== "https:") {
      setSettingsStatus("HTTPS only.", "err");
      return;
    }
    const normalized = url.origin + url.pathname.replace(/\/+$/, "");
    await browser.storage.local.set({
      serverURL: normalized,
      sourceUrlFieldId: null,
    });
    urlInput.value = normalized;
    brandHost.textContent = url.host;

    // Strip ALL whitespace inside the token, not just ends. Django REST
    // Framework's TokenAuthentication rejects "Token <hex>" if <hex> has
    // any spaces (even one accidentally pasted in the middle).
    const token = tokenInput.value.replace(/\s+/g, "");
    if (token) {
      try {
        const res = await browser.runtime.sendMessage({
          op: "forwardNative",
          payload: { op: "setToken", host: url.host, token },
        });
        if (!res?.ok) {
          setSettingsStatus(`Saved URL but token write failed: ${res?.message ?? "unknown"}`, "err");
          return;
        }
        await browser.storage.local.set({ tokenHost: url.host });
        tokenInput.value = "";
        tokenInput.placeholder = "Token saved. Paste a new one to replace.";
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        setSettingsStatus(`Saved URL but token write failed: ${msg}`, "err");
        return;
      }
    }
    setSettingsStatus(`Saved.`, "ok");
    triggerSaveBtn.disabled = false;
    saveHint.hidden = true;
    // After a brief beat, return to the save view so the user can act.
    setTimeout(() => showView("save"), 700);
  });

  triggerSaveBtn.addEventListener("click", async () => {
    triggerSaveBtn.disabled = true;
    setStatus("Saving…", "busy");
    try {
      const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
      if (tab?.id == null) {
        setStatus("No active tab.", "err");
        return;
      }
      const requestId =
        (globalThis as { crypto?: { randomUUID?: () => string } }).crypto?.randomUUID?.() ??
        `${Date.now()}-${Math.random()}`;
      const response = await browser.runtime.sendMessage({
        op: "triggerSave",
        requestId,
        tabId: tab.id,
      });
      if (!response?.ok) {
        const msg = response?.message ?? "Save failed.";
        setStatus(msg, "err");
        announceAlert(msg);
        return;
      }
      if (response.state === "alreadyInFlight") {
        setStatus("Save already in flight.", "warn");
        return;
      }
      const terminal = response.terminal as
        | { state: "succeeded" | "failed" | "timeout"; serverTaskId?: string; errorKind?: string; message?: string }
        | undefined;
      if (terminal?.state === "succeeded") {
        setStatus("Saved to Paperless.", "ok");
        announceStatus("Saved to Paperless.");
      } else if (terminal?.state === "failed") {
        const detail = terminal.message ?? terminal.errorKind ?? "unknown error";
        setStatus(detail, "err");
        announceAlert(`Save failed: ${detail}`);
      } else if (terminal?.state === "timeout") {
        setStatus("Timed out. Check the server.", "err");
      } else {
        setStatus("Save started.", "");
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setStatus(msg, "err");
      announceAlert(msg);
    } finally {
      triggerSaveBtn.disabled = false;
    }
  });

  function setStatus(text: string, level: "ok" | "err" | "warn" | "busy" | "") {
    statusEl.textContent = text;
    statusEl.className = level;
  }

  function setSettingsStatus(text: string, level: "ok" | "err" | "") {
    settingsStatusEl.textContent = text;
    settingsStatusEl.style.color =
      level === "ok" ? "var(--ok)" :
      level === "err" ? "var(--err)" :
      "var(--text-muted)";
  }
});
