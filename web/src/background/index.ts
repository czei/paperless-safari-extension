/**
 * Background service worker for the T019 prototype.
 *
 * Responsibilities:
 *   1. Listen for the toolbar action (browser.action.onClicked) and the
 *      keyboard shortcut (browser.commands.onCommand).
 *   2. For the active tab, call the content script to serialize the page.
 *   3. Pre-flight: notConfigured / httpsRequired / pageCannotBeCaptured.
 *   4. Per-tab debounce (FR-015).
 *   5. Send the serialized HTML to the native handler in chunks
 *      (renderAndUpload.init / .chunk / .commit).
 *   6. Surface user-facing feedback via the popup status view (which reads
 *      via getJobStatus on open) and via accessible announcements.
 *
 * Prototype-only stubs until later tasks land:
 *   - No upload yet (T019 prototype writes PDF locally; T044 wires upload).
 *   - No retry UX (T013 of US1 polish).
 *   - No notifications (post-T048).
 */

import { isRestrictedURL, errorKindFromException } from "../shared/errors";
import type { ErrorKind } from "../shared/messages";

declare const browser: typeof chrome;

const CHUNK_SIZE = 512 * 1024; // 512 KiB per native message — well under any documented payload ceiling.

// Per-tab debounce: tabId -> AbortController
const inFlight = new Map<number, AbortController>();

browser.runtime.onInstalled.addListener(() => {
  console.debug("[paperless-clipper] background worker installed");
});

browser.action.onClicked.addListener((tab) => {
  if (typeof tab.id === "number") {
    void triggerSave(tab.id);
  }
});

browser.commands.onCommand.addListener(async (command) => {
  if (command !== "save-page") return;
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (tab?.id != null) {
    void triggerSave(tab.id);
  }
});

browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (typeof message !== "object" || message === null) return false;
  const op = (message as Record<string, unknown>).op;

  if (op === "triggerSave") {
    const tabId = Number((message as Record<string, unknown>).tabId);
    triggerSave(tabId).then(sendResponse, (err) =>
      sendResponse({ ok: false, error: String(err) }),
    );
    return true;
  }

  // Forwarded native messages from the popup. Routing them through the
  // background context means Safari's "send messages to native app" grant
  // is checked once for the background's lifetime, not per popup-open.
  if (op === "forwardNative") {
    const payload = (message as Record<string, unknown>).payload;
    browser.runtime
      .sendNativeMessage(NATIVE_HANDLER_ID, payload)
      .then(sendResponse, (err) => sendResponse({ ok: false, error: String(err) }));
    return true;
  }

  return false;
});

const NATIVE_HANDLER_ID = "org.czei.PaperlessClipper.Extension";

type NativeOneShotResult = {
  state: "succeeded" | "failed" | "timeout";
  serverTaskId?: string;
  errorKind?: ErrorKind | string;
  message?: string;
};

async function triggerSave(tabId: number): Promise<{ ok: true; state: "started" | "alreadyInFlight"; jobId?: string; terminal?: NativeOneShotResult } | { ok: false; errorKind: ErrorKind; message: string }> {
  if (inFlight.has(tabId)) {
    console.debug("[paperless-clipper] tab", tabId, "already saving");
    return { ok: true, state: "alreadyInFlight" };
  }

  const tab = await browser.tabs.get(tabId);
  if (!tab.url) {
    return { ok: false, errorKind: "pageCannotBeCaptured", message: "Tab has no URL." };
  }
  if (isRestrictedURL(tab.url)) {
    return { ok: false, errorKind: "pageCannotBeCaptured", message: `Cannot save ${new URL(tab.url).protocol} URLs.` };
  }

  const config = await loadServerConfig();
  if (!config) {
    return { ok: false, errorKind: "notConfigured", message: "No Paperless server configured." };
  }
  if (!config.serverURL.startsWith("https://")) {
    return { ok: false, errorKind: "httpsRequired", message: "Paperless server must use HTTPS." };
  }

  const controller = new AbortController();
  inFlight.set(tabId, controller);

  try {
    console.debug("[paperless-clipper] capture starting for tab", tabId);
    const captured = await withTimeout(
      captureTab(tabId),
      30_000,
      "page serialization",
    );
    console.debug(
      `[paperless-clipper] capture done: ${captured.html.length} chars, sending to native`,
    );
    const jobId = crypto.randomUUID();

    // Single sendNativeMessage path when payload fits. Cuts privileged
    // Safari boundary crossings from ~63 (init + N chunks + commit + 60
    // polls) down to 1. Threshold leaves headroom under typical native-
    // messaging payload limits (we've seen ~1 MB work on Safari macOS).
    const ONE_SHOT_LIMIT = 768 * 1024; // ~750 KB UTF-8
    const utf8Bytes = new TextEncoder().encode(captured.html).byteLength;

    let result: NativeOneShotResult;
    if (utf8Bytes <= ONE_SHOT_LIMIT) {
      result = await withTimeout(
        sendOneShot({
          jobId,
          serverURL: config.serverURL,
          captured,
        }),
        90_000,
        "render+upload",
      );
    } else {
      // Large pages still use the chunked path (no JS-side polling here
      // either — chunked path responds when the upload finishes).
      result = await withTimeout(
        sendToNativeChunked({
          jobId,
          serverURL: config.serverURL,
          sourceUrlFieldId: config.sourceUrlFieldId,
          captured,
        }),
        90_000,
        "render+upload (chunked)",
      );
    }
    console.debug("[paperless-clipper] save complete", jobId, result.state);
    return {
      ok: true,
      state: "started",
      jobId,
      terminal: result,
    };
  } catch (e) {
    const { kind, message } = errorKindFromException(e);
    console.error("[paperless-clipper] save failed", kind, message, e);
    return { ok: false, errorKind: kind, message };
  } finally {
    inFlight.delete(tabId);
  }
}

async function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return await Promise.race([
    p,
    new Promise<never>((_resolve, reject) =>
      setTimeout(() => reject(new Error(`${label} timed out after ${ms / 1000}s`)), ms),
    ),
  ]);
}

type ServerConfig = {
  serverURL: string;
  sourceUrlFieldId: number | null;
};

async function loadServerConfig(): Promise<ServerConfig | null> {
  const stored = await browser.storage.local.get(["serverURL", "sourceUrlFieldId"]);
  const serverURL = stored.serverURL as string | undefined;
  if (!serverURL) return null;
  return {
    serverURL,
    sourceUrlFieldId: (stored.sourceUrlFieldId as number | null | undefined) ?? null,
  };
}

type CapturedPage = {
  html: string;
  title: string;
  url: string;
  capturedAt: string;
};

async function captureTab(tabId: number): Promise<CapturedPage> {
  // Step 1: inject content.js into the active tab. Top-level code in the
  // content bundle attaches the serializer to globalThis as
  // __paperlessClipperSerialize.
  await browser.scripting.executeScript({
    target: { tabId },
    files: ["content.js"],
  });
  // Step 2: invoke the global from within the same execution world.
  const [serialized] = await browser.scripting.executeScript({
    target: { tabId },
    func: async () => {
      const g = globalThis as { __paperlessClipperSerialize?: () => Promise<unknown> };
      if (typeof g.__paperlessClipperSerialize !== "function") {
        return { __error: "serializer not attached" };
      }
      try {
        const out = await g.__paperlessClipperSerialize();
        return out;
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        const stack = e instanceof Error ? (e.stack ?? "") : "";
        return { __error: `${message}\n${stack}` };
      }
    },
  });
  const r = serialized?.result as { html?: string; title?: string; url?: string; __error?: string } | undefined;
  if (!r || r.__error || typeof r.html !== "string") {
    throw new Error(`Serialization failed: ${r?.__error ?? "no result"}`);
  }
  return {
    html: r.html,
    title: r.title ?? "",
    url: r.url ?? "",
    capturedAt: new Date().toISOString(),
  };
}

type SendChunkedArgs = {
  jobId: string;
  serverURL: string;
  sourceUrlFieldId: number | null;
  captured: CapturedPage;
};

async function sendOneShot(args: {
  jobId: string;
  serverURL: string;
  captured: CapturedPage;
}): Promise<NativeOneShotResult> {
  const { jobId, serverURL, captured } = args;
  const response = await browser.runtime.sendNativeMessage(NATIVE_HANDLER_ID, {
    op: "renderAndUploadOneShot",
    requestId: jobId,
    serverURL,
    title: captured.title,
    sourceURL: captured.url,
    capturedAt: captured.capturedAt,
    data: captured.html,
  });
  if (!response || typeof response !== "object") {
    return { state: "timeout", message: "no response from native handler" };
  }
  const r = response as Record<string, unknown>;
  return {
    state: (r.state as NativeOneShotResult["state"]) ?? "timeout",
    serverTaskId: r.serverTaskId as string | undefined,
    errorKind: r.errorKind as ErrorKind | undefined,
    message: r.message as string | undefined,
  };
}

async function sendToNativeChunked(args: SendChunkedArgs): Promise<NativeOneShotResult> {
  const { jobId, serverURL, sourceUrlFieldId, captured } = args;
  const utf8 = new TextEncoder().encode(captured.html);
  const totalBytes = utf8.byteLength;
  const totalChunks = Math.max(1, Math.ceil(totalBytes / CHUNK_SIZE));

  // init
  const initResp = await browser.runtime.sendNativeMessage("org.czei.PaperlessClipper.Extension", {
    op: "renderAndUpload.init",
    requestId: jobId,
    serverURL,
    title: captured.title,
    sourceURL: captured.url,
    capturedAt: captured.capturedAt,
    sourceUrlFieldId,
    totalChunks,
    totalBytes,
  });
  if (!initResp?.ok) {
    throw new Error(`init failed: ${initResp?.message ?? "unknown"}`);
  }

  // chunks (string slicing — UTF-16 surrogate pairs on chunk boundaries are
  // handled by passing the source string, not the byte buffer, to the native
  // side; native side encodes on receipt.)
  for (let i = 0; i < totalChunks; i++) {
    const start = i * CHUNK_SIZE;
    const end = Math.min(start + CHUNK_SIZE, captured.html.length);
    const chunk = captured.html.slice(start, end);
    const chunkResp = await browser.runtime.sendNativeMessage("org.czei.PaperlessClipper.Extension", {
      op: "renderAndUpload.chunk",
      requestId: jobId,
      chunkIndex: i,
      data: chunk,
    });
    if (!chunkResp?.ok) {
      throw new Error(`chunk ${i} failed: ${chunkResp?.message ?? "unknown"}`);
    }
  }

  // commit
  const commitResp = await browser.runtime.sendNativeMessage("org.czei.PaperlessClipper.Extension", {
    op: "renderAndUpload.commit",
    requestId: jobId,
  });
  if (!commitResp?.ok || commitResp.state !== "queued") {
    throw new Error(`commit failed: ${commitResp?.message ?? "unknown"}`);
  }

  // Single wait-for-terminal call so the JS layer doesn't poll.
  const waitResp = await browser.runtime.sendNativeMessage("org.czei.PaperlessClipper.Extension", {
    op: "waitForJob",
    requestId: jobId,
  });
  if (!waitResp || typeof waitResp !== "object") {
    return { state: "timeout", message: "no response from waitForJob" };
  }
  const w = waitResp as Record<string, unknown>;
  return {
    state: (w.state as NativeOneShotResult["state"]) ?? "timeout",
    serverTaskId: w.serverTaskId as string | undefined,
    errorKind: w.errorKind as ErrorKind | undefined,
    message: w.message as string | undefined,
  };

  return { state: "queued" };
}

export {};
