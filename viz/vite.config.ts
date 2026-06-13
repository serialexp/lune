import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

// Static SPA: no backend, no router. The visualiser loads a `.lunetrace` the
// user picks from disk and decodes it entirely in the browser.
export default defineConfig({
  plugins: [solid()],
  base: "./",
  build: { target: "esnext", outDir: "dist" },
});
