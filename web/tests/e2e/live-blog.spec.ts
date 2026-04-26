import { test, expect } from "@playwright/test";
import * as path from "path";
import * as fs from "fs";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const WEB_ROOT = path.resolve(__dirname, "../..");
const CONTENT_BUNDLE = path.join(WEB_ROOT, "dist/content.js");
const TARGET_URL = "https://czei.org/blog/multi-llm-spec-driven-development/";

// This is the exact page the user reported hangs forever in Safari. Running
// it through our headless WebKit reproduces the exact same content-script
// path SingleFile takes in production.
test.describe("live blog capture (czei.org)", () => {
  test.beforeEach(async ({ page }) => {
    page.on("console", (msg) => console.log(`[browser:${msg.type()}]`, msg.text()));
    page.on("pageerror", (err) => console.error("[browser:pageerror]", err.message));
  });

  test("captures multi-LLM spec-driven blog post within 20 seconds", async ({ page }) => {
    test.setTimeout(45_000);

    // Use domcontentloaded — same load condition Safari hits when the user
    // clicks "Save" without waiting for the network to settle.
    await page.goto(TARGET_URL, { waitUntil: "domcontentloaded", timeout: 30_000 });

    const bundle = fs.readFileSync(CONTENT_BUNDLE, "utf-8");
    await page.addScriptTag({ content: bundle });

    // Wrap with a hard 20s ceiling — we want a deterministic pass/fail,
    // not an infinite hang.
    const result = (await page.evaluate(async () => {
      const g = globalThis as {
        __paperlessClipperSerialize?: () => Promise<{ html: string; title: string; url: string }>;
      };
      if (typeof g.__paperlessClipperSerialize !== "function") {
        return { __error: "serializer not attached" };
      }
      const startedAt = Date.now();
      let intervalId: number | null = null;
      try {
        intervalId = setInterval(() => {
          console.log(`[paperless-clipper] still serializing after ${Math.round((Date.now() - startedAt) / 1000)}s`);
        }, 2000) as unknown as number;
        const out = await Promise.race([
          g.__paperlessClipperSerialize(),
          new Promise((_resolve, reject) =>
            setTimeout(() => reject(new Error("serializer timed out after 20s")), 20_000),
          ),
        ]);
        return out as { html: string; title: string; url: string };
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        const stack = e instanceof Error ? (e.stack ?? "") : "";
        return { __error: `${message}\n${stack}` };
      } finally {
        if (intervalId != null) clearInterval(intervalId);
      }
    })) as { html?: string; title?: string; url?: string; __error?: string };

    if (result.__error) {
      throw new Error(`live capture failed: ${result.__error}`);
    }
    expect(result.html).toBeTruthy();
    expect(result.html!.length).toBeGreaterThan(1000);
    console.log(
      `[test] captured ${result.html!.length} bytes for "${result.title}" at ${result.url}`,
    );
  });
});
