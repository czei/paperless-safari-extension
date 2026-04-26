/**
 * Page serializer (T024 + T019 prototype) — Readability-backed.
 *
 * The user's goal is "archive the original link, retain enough content to
 * know what it was, ~5 pages max." This is exactly what reader-mode-style
 * extraction does — Mozilla's Readability (the engine behind Firefox
 * Reader View and Safari Reader Mode) pulls out the article's substance
 * and drops navigation, ads, comments, sidebars.
 *
 * Output is wrapped in a clean printable template that includes the
 * source URL prominently so the link survives even if Paperless can't
 * find a custom field to attach it to.
 *
 * MIT-licensed. ~50 KB bundled vs SingleFile's ~1.2 MB.
 */

// @ts-expect-error — index.d.ts ships ESM types but the runtime is CJS,
// vite handles the interop. Suppress the specific complaint here.
import { Readability, isProbablyReaderable } from "@mozilla/readability";

export type SerializedPage = {
  html: string;
  title: string;
  url: string;
};

async function serializeActiveDocument(): Promise<SerializedPage> {
  console.debug("[paperless-clipper] serializeActiveDocument invoked (Readability)");

  const url = location.href;
  const lang = document.documentElement.lang || "en";
  const fallbackTitle = document.title || url;

  // Readability mutates the document it parses. Clone first so the user's
  // live page in Safari isn't disturbed.
  const clone = document.cloneNode(/* deep */ true) as Document;

  let title = fallbackTitle;
  let byline = "";
  let publishedTime = "";
  let articleHTML = "";

  try {
    if (isProbablyReaderable(document)) {
      const reader = new Readability(clone, {
        // Default cleanup is fine. We could tighten with charThreshold etc.
        // but the defaults handle czei.org / Reddit / Wikipedia well.
      });
      const article = reader.parse();
      if (article) {
        title = article.title || fallbackTitle;
        byline = article.byline || "";
        publishedTime = article.publishedTime || "";
        articleHTML = article.content || "";
      }
    }
  } catch (e) {
    console.warn("[paperless-clipper] Readability failed; falling back", e);
  }

  // Fallback when the page isn't reader-able (homepages, dashboards, search
  // results) OR when Readability returns nothing. We capture the document's
  // <main>/<article>/<body> innerHTML as best-effort. The user's stated
  // goal — "enough to know what it was" — is satisfied either way because
  // we include the source URL prominently.
  if (!articleHTML) {
    const root =
      document.querySelector("main") ||
      document.querySelector("article") ||
      document.body;
    articleHTML = root ? root.innerHTML : `<p><em>(no content extracted)</em></p>`;
  }

  const html = renderArchiveTemplate({
    lang,
    title,
    byline,
    publishedTime,
    sourceURL: url,
    articleHTML,
  });

  return { html, title, url };
}

type TemplateInput = {
  lang: string;
  title: string;
  byline: string;
  publishedTime: string;
  sourceURL: string;
  articleHTML: string;
};

function renderArchiveTemplate(t: TemplateInput): string {
  const { lang, title, byline, publishedTime, sourceURL, articleHTML } = t;
  const formattedDate = formatDateMaybe(publishedTime);
  const meta = [byline, formattedDate].filter(Boolean).join(" · ");

  return `<!DOCTYPE html>
<html lang="${escapeAttr(lang)}">
<head>
<meta charset="utf-8">
<title>${escapeText(title)}</title>
<link rel="canonical" href="${escapeAttr(sourceURL)}">
<meta name="paperless-clipper:source-url" content="${escapeAttr(sourceURL)}">
${publishedTime ? `<meta name="paperless-clipper:published" content="${escapeAttr(publishedTime)}">` : ""}
<style>
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", "Segoe UI", system-ui, sans-serif;
    max-width: 720px;
    margin: 40px auto;
    padding: 0 24px 40px;
    color: #222;
    line-height: 1.55;
    font-size: 12pt;
  }
  .pc-source {
    margin: 0 0 24px;
    padding: 12px 16px;
    border-left: 3px solid #999;
    background: #f7f7f5;
    font-size: 10.5pt;
    color: #555;
    word-break: break-all;
  }
  .pc-source a {
    color: #0366d6;
    text-decoration: underline;
    text-decoration-thickness: 1px;
    text-underline-offset: 2px;
  }
  .pc-source a:visited { color: #0366d6; }
  .pc-source-label { color: #777; font-size: 9.5pt; text-transform: uppercase; letter-spacing: 0.04em; margin: 0 0 4px; }
  h1.pc-title { margin: 0 0 8px; font-size: 22pt; line-height: 1.2; color: #111; }
  .pc-meta { margin: 0 0 28px; font-size: 11pt; color: #666; }
  article p { margin: 0 0 1em; }
  article h2 { font-size: 15pt; margin: 1.4em 0 0.5em; color: #111; }
  article h3 { font-size: 12.5pt; margin: 1.2em 0 0.4em; color: #111; }
  article a { color: #0366d6; }
  article img, article video { max-width: 100%; height: auto; }
  article pre, article code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 10.5pt;
    background: #f6f8fa;
  }
  article pre { padding: 12px; overflow: auto; border-radius: 4px; }
  article code { padding: 2px 4px; border-radius: 3px; }
  article blockquote {
    margin: 1em 0;
    padding-left: 16px;
    border-left: 3px solid #ddd;
    color: #555;
  }
  @media print { body { margin: 0; max-width: none; } }
</style>
</head>
<body>
<aside class="pc-source">
  <p class="pc-source-label">Source</p>
  <a href="${escapeAttr(sourceURL)}" target="_blank" rel="noopener noreferrer">${escapeText(sourceURL)}</a>
</aside>
<h1 class="pc-title">${escapeText(title)}</h1>
${meta ? `<p class="pc-meta">${escapeText(meta)}</p>` : ""}
<article>
${articleHTML}
</article>
</body>
</html>`;
}

function formatDateMaybe(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
}

function escapeText(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function escapeAttr(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

// Attach the global so the background script can invoke this serializer.
(
  globalThis as { __paperlessClipperSerialize?: typeof serializeActiveDocument }
).__paperlessClipperSerialize = serializeActiveDocument;

console.debug("[paperless-clipper] content script attached serializer (Readability)");
