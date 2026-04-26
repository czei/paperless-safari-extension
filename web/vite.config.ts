import { defineConfig } from "vite";
import { resolve } from "node:path";

export default defineConfig({
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2020",
    rollupOptions: {
      input: {
        // JS-only entries (no HTML host page).
        background: resolve(__dirname, "src/background/index.ts"),
        // content.js is built by a separate vite invocation
        // (vite.content.config.ts) so SingleFile can be inlined.
        // HTML-driven entries (HTML lives at web/ root so vite emits flat).
        popup: resolve(__dirname, "popup.html"),
        settings: resolve(__dirname, "settings.html"),
      },
      output: {
        // Stable filenames — no content hashes. xcodegen captures the file
        // list at generate-time; hashed names would mean re-running xcodegen
        // on every code change. Cache-busting is not needed for an extension
        // bundle (Safari loads from disk, not over HTTP).
        entryFileNames: "[name].js",
        chunkFileNames: "[name].js",
        assetFileNames: "[name][extname]",
        format: "es",
      },
    },
    sourcemap: true,
    minify: false,
  },
});
