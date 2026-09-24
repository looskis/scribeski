import { defineConfig, devices } from "@playwright/test";

// WebKit only: production runs in Safari. Headless and CI-safe.
export default defineConfig({
  testDir: "test",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? "github" : "list",
  use: { baseURL: "http://127.0.0.1:8787" },
  projects: [{ name: "webkit", use: { ...devices["Desktop Safari"] } }],
  webServer: {
    command: "node scripts/serve.mjs ../fixtures/mock-ehr 8787",
    url: "http://127.0.0.1:8787/index.html",
    reuseExistingServer: !process.env.CI,
  },
});
