import { expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("the local TUI entrypoint loads without installing development dependencies", () => {
  const directory = mkdtempSync(join(tmpdir(), "opencode-nvim-entry-"));
  try {
    mkdirSync(join(directory, "tui-plugin"));
    for (const file of ["package.json", "tui.ts", "tui-plugin/tui.ts", "tui-plugin/bridge.ts"]) {
      copyFileSync(new URL(`../${file}`, import.meta.url), join(directory, file));
    }
    writeFileSync(join(directory, "check.ts"), `
      import plugin from "./tui.ts";
      if (plugin.id !== "opencode-nvim-bridge" || typeof plugin.setup !== "function") {
        throw new Error("Invalid native TUI plugin definition");
      }
    `);
    const result = Bun.spawnSync([process.execPath, "--no-install", "check.ts"], { cwd: directory });
    expect(result.stderr.toString()).toBe("");
    expect(result.exitCode).toBe(0);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
