import { test, expect } from "@playwright/test";
import * as path from "path";
import * as fs from "fs";
import { fileURLToPath } from "url";

// Tests live at web/tests/e2e/. Bundle is at web/dist/content.js.
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const WEB_ROOT = path.resolve(__dirname, "../..");
const CONTENT_BUNDLE = path.join(WEB_ROOT, "dist/content.js");
const FIXTURE_PATH = path.join(__dirname, "fixtures/simple-page.html");

test.describe("content script serializer", () => {
  test.beforeEach(async ({ page }) => {
    // Forward console + page errors to the test runner so failures show the
    // actual cause (this is the whole point — manual Safari debugging is
    // what we're escaping).
    page.on("console", (msg) => {
      console.log(`[browser:${msg.type()}]`, msg.text());
    });
    page.on("pageerror", (err) => {
      console.error("[browser:pageerror]", err.message);
    });
  });

  test("attaches __paperlessClipperSerialize on globalThis", async ({ page }) => {
    await page.goto(`file://${FIXTURE_PATH}`);

    const bundle = fs.readFileSync(CONTENT_BUNDLE, "utf-8");
    await page.addScriptTag({ content: bundle });

    const isAttached = await page.evaluate(() => {
      const g = globalThis as { __paperlessClipperSerialize?: unknown };
      return typeof g.__paperlessClipperSerialize === "function";
    });

    expect(isAttached).toBe(true);
  });

  test("serializer returns a self-contained HTML snapshot", async ({ page }) => {
    await page.goto(`file://${FIXTURE_PATH}`);

    const bundle = fs.readFileSync(CONTENT_BUNDLE, "utf-8");
    await page.addScriptTag({ content: bundle });

    const result = (await page.evaluate(async () => {
      const g = globalThis as {
        __paperlessClipperSerialize?: () => Promise<{ html: string; title: string; url: string }>;
      };
      if (typeof g.__paperlessClipperSerialize !== "function") {
        return { __error: "serializer not attached" };
      }
      try {
        return await g.__paperlessClipperSerialize();
      } catch (e) {
        return { __error: e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e) };
      }
    })) as { html?: string; title?: string; url?: string; __error?: string };

    if (result.__error) {
      throw new Error(`serializer threw: ${result.__error}`);
    }
    expect(result.html).toBeTruthy();
    expect(result.title).toContain("Fixture");
    expect(result.url).toContain("simple-page.html");
  });

  test("snapshot preserves article body and embeds source URL", async ({ page }) => {
    await page.goto(`file://${FIXTURE_PATH}`);

    const bundle = fs.readFileSync(CONTENT_BUNDLE, "utf-8");
    await page.addScriptTag({ content: bundle });

    const result = (await page.evaluate(async () => {
      const g = globalThis as {
        __paperlessClipperSerialize?: () => Promise<{ html: string }>;
      };
      try {
        return await g.__paperlessClipperSerialize!();
      } catch (e) {
        return { __error: e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e) };
      }
    })) as { html?: string; __error?: string };

    if (result.__error || !result.html) {
      throw new Error(`serializer failed: ${result.__error ?? "no html"}`);
    }
    // Readability extracts article body, drops decorative chrome. We want
    // the article text and the source URL preserved in the archive.
    expect(result.html).toContain("Fixture: Simple Page");
    expect(result.html).toContain("This fixture exercises a few features");
    expect(result.html).toContain("simple-page.html"); // source URL embedded
    expect(result.html.length).toBeGreaterThan(500);
  });
});
