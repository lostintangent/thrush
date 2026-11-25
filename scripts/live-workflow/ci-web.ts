// Toy Box's hosted PTY check needs no web animation. Prepare only a disposable checkout.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { $ } from "bun";

const [, , repository, revision, provenance] = process.argv;
assert(repository && revision && provenance, "Usage: bun ci-web.ts DISPOSABLE_CHECKOUT REVISION REPORT");
process.chdir(repository);
assert.equal((await $`git rev-parse HEAD`.text()).trim(), revision);
assert.equal((await $`git status --porcelain`.text()).trim(), "");
const originalTree = (await $`git rev-parse HEAD^{tree}`.text()).trim();
async function lockPackages(): Promise<Record<string, unknown[]>> {
    const document = Bun.JSONC.parse(await readFile("bun.lock", "utf8")) as { packages: Record<string, unknown[]> };
    return document.packages;
}
const originalLock = await lockPackages();
const importers = (await $`git grep -l -F motion-plus/react -- src`.text()).trim().split("\n");
assert.deepEqual(importers, ["src/features/sessions/components/sidebar/SessionListItem.tsx", "src/shared/attachments/AttachmentGallery.tsx"]);

const stub = "thrush-ci-web-animation";
await mkdir(stub);
await writeFile(stub + "/package.json", JSON.stringify({
    name: "motion-plus", version: "0.0.0", private: true, type: "module", exports: { "./react": "./react.js" },
}) + "\n");
await writeFile(stub + "/react.js", [
    "export const Typewriter = ({ children }) => children;",
    "export const Carousel = ({ items }) => items;",
    "export const useCarousel = () => ({});",
].join("\n") + "\n");
const manifest = JSON.parse(await readFile("package.json", "utf8"));
assert(manifest.devDependencies["motion-plus"].startsWith("npm:@motionplus/core@"));
manifest.devDependencies["motion-plus"] = "file:" + stub;
await writeFile("package.json", JSON.stringify(manifest, null, 2) + "\n");
const config = await readFile("bunfig.toml", "utf8");
const registry = /^motionplus\s*=.*\n/m;
assert(registry.test(config), "Expected the web animation registry in the pinned Bun configuration");
await writeFile("bunfig.toml", config.replace(registry, ""));
// Resolve the local file alias once. The normal server builder uses the resulting frozen lock.
await $`bun install --lockfile-only --ignore-scripts`;
const publicLock = await lockPackages();
for (const [name, pkg] of Object.entries(publicLock)) {
    if (name === "motion-plus") continue;
    const before = originalLock[name], after = pkg;
    // Bun can normalize registry URLs. Verify package identities, metadata and integrity digests.
    assert(before && after[0] === before[0], "Unexpected dependency version for " + name);
    assert.deepEqual(after.slice(2), before.slice(2), "Unexpected lock metadata for " + name);
}
const files = (await $`git ls-files --modified --others --exclude-standard`.text()).trim().split("\n").sort();
assert.deepEqual(files, ["bun.lock", "bunfig.toml", "package.json", stub + "/package.json", stub + "/react.js"]);
const patchedFiles: Record<string, string> = {};
for (const file of files) patchedFiles[file] = createHash("sha256").update(await readFile(file)).digest("hex");
await writeFile(resolve(provenance), JSON.stringify({ originalTree, patchedFiles }, null, 2) + "\n");
