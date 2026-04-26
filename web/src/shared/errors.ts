/**
 * Error categories for the extension. Mirrors `shared-swift/Models.swift`
 * `ErrorKind` enum 1:1 to keep JS and Swift in sync.
 */
import type { ErrorKind } from "./messages";

export const ERROR_LABELS: Record<ErrorKind, string> = {
  notConfigured: "Set up your Paperless server in settings to start saving pages.",
  httpsRequired: "Paperless server URL must use HTTPS.",
  cannotReachServer: "Couldn't reach the Paperless server.",
  authRejected: "Paperless rejected the API token. Check settings.",
  pageCannotBeCaptured: "This page can't be saved.",
  serverRejectedUpload: "Paperless wouldn't accept the upload.",
  tooLarge: "This page is too large to save.",
  cancelled: "Save cancelled.",
  unknown: "Save failed.",
};

export function labelFor(kind: ErrorKind, detail?: string): string {
  const base = ERROR_LABELS[kind];
  if (!detail) return base;
  return `${base} ${detail}`;
}

/**
 * Map an HTTP response (status + optional body) into an ErrorKind. The body
 * is included for `serverRejectedUpload` so the user gets a specific reason.
 */
export function errorKindFromHTTP(status: number): ErrorKind {
  if (status >= 200 && status < 300) return "unknown"; // success — caller shouldn't be here
  if (status === 401 || status === 403) return "authRejected";
  if (status === 413) return "tooLarge";
  if (status >= 400 && status < 500) return "serverRejectedUpload";
  if (status >= 500 && status < 600) return "serverRejectedUpload";
  return "unknown";
}

/**
 * Map a raw thrown error / abort to an ErrorKind. Used for fetch failures
 * and IPC failures.
 */
export function errorKindFromException(e: unknown): { kind: ErrorKind; message: string } {
  if (e instanceof DOMException && e.name === "AbortError") {
    return { kind: "cancelled", message: "Save cancelled." };
  }
  if (e instanceof TypeError) {
    // fetch() throws TypeError for network failures (DNS, TLS, refused).
    return { kind: "cannotReachServer", message: "Network error reaching the server." };
  }
  const message = e instanceof Error ? e.message : String(e);
  return { kind: "unknown", message };
}

/**
 * Restricted-URL detection (FR-011). Returns true if the extension may not
 * read the active tab's content.
 */
export function isRestrictedURL(url: string): boolean {
  try {
    const u = new URL(url);
    if (u.protocol === "about:" || u.protocol === "chrome:" || u.protocol === "safari-extension:")
      return true;
    if (u.protocol === "file:") return true;
    if (u.hostname === "" && u.protocol !== "https:" && u.protocol !== "http:") return true;
    return false;
  } catch {
    return true;
  }
}
