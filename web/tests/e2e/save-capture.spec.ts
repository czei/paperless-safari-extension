import { test } from "@playwright/test";
import * as path from "path";
import * as fs from "fs";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const WEB_ROOT = path.resolve(__dirname, "../..");
const CONTENT_BUNDLE = path.join(WEB_ROOT, "dist/content.js");
const TARGET_URL = "https://czei.org/blog/multi-llm-spec-driven-development/";
const OUT_PATH = "/tmp/singlefile-capture.html";

// One-off: capture the user's blog with the current serializer and write
// the result to /tmp so it can be opened in a real browser to inspect
// quality. Not part of regular CI.
test("dump capture of czei.org blog to /tmp/singlefile-capture.html", async ({ page }) => {
  test.setTimeout(60_000);
  await page.goto(TARGET_URL, { waitUntil: "domcontentloaded" });
  const bundle = fs.readFileSync(CONTENT_BUNDLE, "utf-8");
  await page.addScriptTag({ content: bundle });

  const result = (await page.evaluate(async () => {
    const g = globalThis as {
      __paperlessClipperSerialize?: () => Promise<{ html: string; title: string; url: string }>;
    };
    return await g.__paperlessClipperSerialize!();
  })) as { html: string; title: string; url: string };

  fs.writeFileSync(OUT_PATH, result.html, "utf-8");
  console.log(`[test] wrote ${result.html.length} bytes to ${OUT_PATH}`);
});
