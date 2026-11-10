import { defineConfig } from "vitest/config";

// The test runner's config, kept apart from vite.config.ts so the suite does
// not load the dev-server plugins.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    setupFiles: ["test/setup.ts"],
  },
});
