// Runs zisp.wasm under Node's WASI with the current directory preopened.
// Usage: node scripts/run-wasi.mjs zig-out/bin/zisp.wasm [zisp arguments...]
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";
import { argv, env, exit } from "node:process";

const [wasmPath, ...args] = argv.slice(2);
const wasi = new WASI({
  version: "preview1",
  args: ["zisp", ...args],
  env,
  preopens: { ".": "." },
  returnOnExit: true,
});
const module = await WebAssembly.compile(await readFile(wasmPath));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
exit(wasi.start(instance));
