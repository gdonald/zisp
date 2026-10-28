// Runs examples/wasm-repl/demo.lisp in zisp built for wasm32-freestanding,
// through the same examples/wasm-repl/zisp.js a page uses, and checks
// what it printed and what it logged to the console.
// Usage: node tests/run-wasm-repl.mjs zig-out/web/zisp.wasm
import { readFile } from "node:fs/promises";
import { argv, exit } from "node:process";
import "../examples/wasm-repl/zisp.js";

const logged = [];
const consoleLog = console.log;
console.log = (...items) => {
  logged.push(items.join(" "));
};

const zisp = globalThis.loadZisp(await readFile(argv[2]));
const demo = zisp.evaluate(await readFile(new URL("../examples/wasm-repl/demo.lisp", import.meta.url), "utf8"));
const before = Date.now();
const now = Number(zisp.evaluate(`(js:call "Date.now")`).output.trim());
const after = Date.now();
const checks = zisp.evaluate(`
(list (js:call "Math.max" 3 9 4)
      (js:call "String" #\\a)
      (js:call "Array.of" 1 2.5d0 "x" t :false nil)
      (js:call "JSON.parse" "{\\"a\\": [1, {\\"b\\": null}]}")
      (js:call "Number.parseInt" "12345678901234567890"))
(handler-case (js:call "not.there") (error () :signaled))
(handler-case (js:call "Math.max" 'symbol) (type-error () :signaled))
(js:call "console.log" "after a failed call")`);
console.log = consoleLog;

const lines = demo.output.trim().split("\n");
const failures = [];
function expect(label, actual, wanted) {
  if (actual !== wanted) failures.push(`${label}: got ${JSON.stringify(actual)}, wanted ${JSON.stringify(wanted)}`);
}
expect("demo evaluated", demo.ok, true);
expect("first console.log", logged[0], "hello");
expect("console.log result", lines[0], "NIL");
expect("Date.now is a time during the run", now >= before && now <= after, true);
expect("second console.log", /^fib 18 took \d+ ms$/.test(logged[1]), true);
expect("Math.max", lines[6], "9");
expect("JSON.parse object", lines[7], '(("name" . "zisp") ("tags" . #("lisp" "zig")))');
expect("thrown error", lines[8].startsWith('"JavaScript: '), true);
expect("checks evaluated", checks.ok, true);
expect("conversions", checks.output.split("\n")[0],
  '(9 "a" #(1 2.5d0 "x" T :FALSE NIL) (("a" . #(1 (("b"))))) 1.2345678901234567d19)');
expect("missing function", checks.output.split("\n")[1], ":SIGNALED");
expect("unconvertible argument", checks.output.split("\n")[2], ":SIGNALED");
expect("log after a failed call", logged[2], "after a failed call");

if (failures.length > 0) {
  console.error(failures.join("\n"));
  console.error(demo.output);
  console.error(checks.output);
  exit(1);
}
console.log("wasm repl: every check passed");
