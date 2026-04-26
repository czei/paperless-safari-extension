// Popup UI for the T019 prototype.
//
// Two affordances:
//   * Configure server URL + API token (token is stored in the platform
//     Keychain via a setToken native message; never persists in
//     browser.storage.local)
//   * Trigger a save of the active tab
//
// The settings UI in Phase 5 (US2) will move configuration into the
// containing app and reduce this popup to a status surface.
import { ensureLiveRegions, announceStatus, announceAlert } from "../shared/a11y";

declare const browser: typeof chrome;


document.addEventListener("DOMContentLoaded", () => {
  ensureLiveRegions();

  const urlInput = document.getElementById("server-url") as HTMLInputElement;
  const tokenInput = document.getElementById("api-token") as HTMLInputElement;
  const saveConfigBtn = document.getElementById("save-config") as HTMLButtonElement;
  const triggerSaveBtn = document.getElementById("trigger-save") as HTMLButtonElement;
  const statusEl = document.getElementById("status") as HTMLParagraphElement;

  // Load any previously-saved URL.
  void browser.storage.local.get(["serverURL", "tokenHost"]).then((stored) => {
    const existing = (stored as Record<string, unknown>).serverURL;
    if (typeof existing === "string") {
      urlInput.value = existing;
    }
    // Token is in Keychain; never readable from JS. Just hint at presence.
    if ((stored as Record<string, unknown>).tokenHost) {
      tokenInput.placeholder = "Token already saved. Paste a new one to replace.";
    }
  });

  saveConfigBtn.addEventListener("click", async () => {
    const raw = urlInput.value.trim();
    if (!raw) {
      setStatus("Enter a server URL.", "err");
      return;
    }
    let url: URL;
    try {
      url = new URL(raw);
    } catch {
      setStatus("Not a valid URL.", "err");
      return;
    }
    if (url.protocol !== "https:") {
      setStatus("HTTPS only.", "err");
      return;
    }
    const normalized = url.origin + url.pathname.replace(/\/+$/, "");
    await browser.storage.local.set({
      serverURL: normalized,
      sourceUrlFieldId: null,
    });
    urlInput.value = normalized;

    // Note: we don't call permissions.request for the Paperless origin —
    // the extension never fetches from it. The containing app does, and
    // it's not subject to web-extension host permissions.

    const token = tokenInput.value.trim();
    if (token) {
      try {
        const res = await browser.runtime.sendMessage({
          op: "forwardNative",
          payload: { op: "setToken", host: url.host, token },
        });
        if (!res?.ok) {
          setStatus(`Saved URL but token write failed: ${res?.message ?? "unknown"}`, "err");
          return;
        }
        await browser.storage.local.set({ tokenHost: url.host });
        tokenInput.value = "";
        tokenInput.placeholder = "Token saved. Paste a new one to replace.";
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        setStatus(`Saved URL but token write failed: ${msg}`, "err");
        return;
      }
    }
    setStatus(`Saved settings for ${url.host}`, "ok");
  });

  triggerSaveBtn.addEventListener("click", async () => {
    triggerSaveBtn.disabled = true;
    setStatus("Saving…", "");
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
        setStatus(`${response?.errorKind ?? "error"}: ${msg}`, "err");
        announceAlert(msg);
        return;
      }
      if (response.state === "alreadyInFlight") {
        setStatus("Save already in flight.", "");
        return;
      }
      // Background returns one synchronous-looking result: the native
      // handler internally waited for terminal state, so no JS polling.
      const terminal = response.terminal as
        | { state: "succeeded" | "failed" | "timeout"; serverTaskId?: string; errorKind?: string; message?: string }
        | undefined;
      if (terminal?.state === "succeeded") {
        const taskId = terminal.serverTaskId ?? "(unknown)";
        setStatus(`Saved to Paperless. Task ${taskId}.`, "ok");
        announceStatus("Saved to Paperless.");
      } else if (terminal?.state === "failed") {
        const detail = terminal.message ? `: ${terminal.message}` : "";
        setStatus(`Failed (${terminal.errorKind ?? "unknown"})${detail}`, "err");
        announceAlert(`Save failed: ${terminal.message ?? terminal.errorKind ?? "unknown"}`);
      } else if (terminal?.state === "timeout") {
        setStatus("Timed out waiting for Paperless. Check the server directly.", "err");
      } else {
        setStatus("Save started (no terminal info).", "");
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setStatus(`Error: ${msg}`, "err");
      announceAlert(msg);
    } finally {
      triggerSaveBtn.disabled = false;
    }
  });

  // Polling removed: the background's triggerSave now embeds terminal state
  // directly in its response. The native handler waits internally for the
  // job to finish before returning, so the JS layer makes ONE
  // sendNativeMessage instead of 60 polling calls (per pal-debate consensus).

  function setStatus(text: string, level: "ok" | "err" | "") {
    statusEl.textContent = text;
    statusEl.className = level;
  }
});
