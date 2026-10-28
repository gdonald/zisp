// Loads zisp built for wasm32-freestanding and evaluates text in it.
// A classic script, so a page opened from disk can load it, and Node can
// import it. docs/wasm-interop.md describes the `zisp_js_call` bridge.

globalThis.loadZisp = function loadZisp(wasmBytes) {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let zisp = null;

  function readText(pointer, length) {
    return decoder.decode(new Uint8Array(zisp.memory.buffer, pointer, length));
  }

  function writeText(text) {
    const bytes = encoder.encode(text);
    const pointer = zisp.zisp_alloc(bytes.length);
    new Uint8Array(zisp.memory.buffer, pointer, bytes.length).set(bytes);
    return [pointer, bytes.length];
  }

  function lookUp(name) {
    const path = name.split(".");
    let receiver = globalThis;
    for (const property of path.slice(0, -1)) receiver = receiver[property];
    const target = receiver[path[path.length - 1]];
    if (typeof target !== "function") throw new Error(`${name} is not a function`);
    return [receiver, target];
  }

  function jsCall(pointer, length) {
    const request = JSON.parse(readText(pointer, length));
    let status = 0;
    let replyText;
    try {
      const [receiver, target] = lookUp(request.function);
      const result = target.apply(receiver, request.arguments);
      replyText = JSON.stringify(result === undefined ? null : result);
    } catch (error) {
      status = 1;
      replyText = String(error && error.message ? error.message : error);
    }
    zisp.zisp_reply(...writeText(replyText));
    return status;
  }

  const instance = new WebAssembly.Instance(new WebAssembly.Module(wasmBytes), {
    env: { zisp_js_call: jsCall },
  });
  zisp = instance.exports;
  if (zisp.zisp_init() !== 0) throw new Error("zisp did not start");

  return {
    // Every form in `text` is read, evaluated and printed, as at the REPL.
    // `ok` is false when a form could not be read or evaluated.
    evaluate(text) {
      const [pointer, length] = writeText(text);
      const status = zisp.zisp_eval(pointer, length);
      zisp.zisp_free(pointer, length);
      return { ok: status === 0, output: readText(zisp.zisp_output_ptr(), zisp.zisp_output_len()) };
    },
  };
};
