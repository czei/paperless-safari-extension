/**
 * Accessible feedback helpers (FR-010).
 *
 * Visible text alone is not sufficient for VoiceOver users. The popup uses
 * an ARIA live region pair — `role="status"` for success, `role="alert"`
 * for failure — so screen readers receive explicit audio confirmation of
 * every save outcome.
 */

const STATUS_ID = "paperless-clipper-status-region";
const ALERT_ID = "paperless-clipper-alert-region";

/**
 * Ensure the live regions exist in the host document. Idempotent — call as
 * many times as you like; only the first call creates the elements.
 */
export function ensureLiveRegions(host: Document = document): void {
  if (!host.getElementById(STATUS_ID)) {
    const status = host.createElement("div");
    status.id = STATUS_ID;
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    status.setAttribute("aria-atomic", "true");
    // Visually hidden but available to assistive tech.
    Object.assign(status.style, srOnlyStyle);
    host.body.appendChild(status);
  }
  if (!host.getElementById(ALERT_ID)) {
    const alert = host.createElement("div");
    alert.id = ALERT_ID;
    alert.setAttribute("role", "alert");
    alert.setAttribute("aria-live", "assertive");
    alert.setAttribute("aria-atomic", "true");
    Object.assign(alert.style, srOnlyStyle);
    host.body.appendChild(alert);
  }
}

/** Announce a non-urgent status update (e.g., "Saved to Paperless."). */
export function announceStatus(message: string, host: Document = document): void {
  ensureLiveRegions(host);
  const region = host.getElementById(STATUS_ID);
  if (region) {
    // Clearing first ensures repeated identical messages still announce.
    region.textContent = "";
    setTimeout(() => {
      region.textContent = message;
    }, 50);
  }
}

/** Announce a failure that needs the user's attention. */
export function announceAlert(message: string, host: Document = document): void {
  ensureLiveRegions(host);
  const region = host.getElementById(ALERT_ID);
  if (region) {
    region.textContent = "";
    setTimeout(() => {
      region.textContent = message;
    }, 50);
  }
}

const srOnlyStyle: Partial<CSSStyleDeclaration> = {
  position: "absolute",
  width: "1px",
  height: "1px",
  padding: "0",
  margin: "-1px",
  overflow: "hidden",
  clip: "rect(0, 0, 0, 0)",
  whiteSpace: "nowrap",
  border: "0",
};
