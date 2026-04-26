import { defineConfig } from "vite";
import { resolve } from "node:path";

// Separate vite config for the content script alone, so we can apply
// `inlineDynamicImports: true` (which conflicts with multiple entries).
// SingleFile gets inlined into content.js — Safari content scripts can't
// dynamically load chunk files from the extension URL space.
export default defineConfig({
  build: {
    outDir: "dist",
    emptyOutDir: false, // run after the main build, don't wipe its output
    target: "es2020",
    rollupOptions: {
      input: resolve(__dirname, "src/content/serialize.ts"),
      output: {
        entryFileNames: "content.js",
        chunkFileNames: "content.js",
        assetFileNames: "[name][extname]",
        // IIFE wraps everything in a self-invoking function — no module
        // syntax, no `import.meta`. Required because content scripts load
        // as classic scripts, where `import.meta` is a parse error and
        // kills the whole script.
        format: "iife",
        name: "PaperlessClipperContent",
        inlineDynamicImports: true,
      },
    },
    sourcemap: true,
    minify: false,
  },
});
