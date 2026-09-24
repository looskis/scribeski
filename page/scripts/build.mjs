// Bundles src/index.ts into one IIFE: dist/scribeski-page.js.
// The bundle must never contain eval or new Function (strict-CSP pages; BUILD_PLAN P1.1).
import { build } from "esbuild";
import { copyFileSync, readFileSync } from "node:fs";

const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url)));

await build({
  entryPoints: [new URL("../src/index.ts", import.meta.url).pathname],
  outfile: new URL("../dist/scribeski-page.js", import.meta.url).pathname,
  bundle: true,
  format: "iife",
  target: "safari17",
  legalComments: "none",
  banner: { js: `/* scribeski-page ${version} */` },
  define: { __SCRIBESKI_VERSION__: JSON.stringify(version) },
});

const out = readFileSync(new URL("../dist/scribeski-page.js", import.meta.url), "utf8");
if (/\beval\s*\(|new\s+Function\s*\(/.test(out)) {
  console.error("dist/scribeski-page.js contains eval or new Function");
  process.exit(1);
}
// The Swift FormDriver embeds the bundle as a resource. Committed, and CI checks it's current.
copyFileSync(
  new URL("../dist/scribeski-page.js", import.meta.url),
  new URL("../../Sources/FormDriver/Resources/scribeski-page.js", import.meta.url),
);
console.log(`built dist/scribeski-page.js (${out.length} bytes, v${version})`);
