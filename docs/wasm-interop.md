# JavaScript interop

zisp built for `wasm32-freestanding` (`zig build wasm`) can call
JavaScript functions in its host and use what they return.

```lisp
(js:call "console.log" "hello")       ; prints hello in the host's console, => NIL
(js:call "Date.now")                  ; => 1761609600000
(js:call "Math.max" 3 9 4)            ; => 9
```

## Surface

`(js:call name &rest arguments)` calls the JavaScript function `name`
with `arguments` and returns its result. `name` is a string of property
names separated by dots, looked up from `globalThis`, so `"Date.now"` is
`globalThis.Date.now`. The function is called with the object before the
last dot as `this`, which `console.log` needs in some browsers.

A JavaScript exception thrown by the function signals a Lisp `error`
whose message is the exception's message. A name that does not lead to a
function signals the same way.

## Values

Arguments and results cross as JSON, so only values JSON can hold cross.

| Lisp | JavaScript |
| --- | --- |
| NIL | `null` |
| T | `true` |
| `:false` | `false` |
| integer | number |
| float | number |
| string, character | string |
| vector, or a list other than NIL | array |

Going the other way, `null` and `undefined` become NIL, `true` T, `false`
`:false`, an integral number an integer, any other number a
`double-float`, a string a string, an array a simple vector, and an
object an association list of `(key . value)` with string keys. A Lisp
value outside the table, such as a symbol other than those three or a
hash table, signals a `type-error` before the call is made.

## The bridge

The module imports one function and exports the rest of what the host
needs.

| Name | Direction | Type | What it does |
| --- | --- | --- | --- |
| `env.zisp_js_call` | import | `(ptr, len) -> status` | Make the call described by the `len` bytes of JSON at `ptr` |
| `zisp_alloc` | export | `(len) -> ptr` | `len` bytes for the host to write into |
| `zisp_free` | export | `(ptr, len)` | Give them back |
| `zisp_reply` | export | `(ptr, len)` | Hand zisp the reply to the call in progress |

A call goes in four steps.

1. `js:call` builds the request, a JSON object such as
   `{"function":"Math.max","arguments":[3,9,4]}`, and calls the imported
   `zisp_js_call` with its address and length.
2. The host decodes the request, makes the call, and encodes the result
   with `JSON.stringify`, turning `undefined` into `null`.
3. The host writes the encoded reply into memory it takes from
   `zisp_alloc`, and passes it to `zisp_reply`, which keeps that
   pointer and length. Taking memory can grow it, so the host makes a new
   view of `memory.buffer` after `zisp_alloc` returns.
4. `zisp_js_call` returns 0 when the function returned and 1 when it
   threw. zisp reads the reply as the result for 0, or as the error
   message for 1, and frees it.

`examples/wasm-repl/zisp.js` is the host side. It passes the import when
it instantiates the module.

## Worked example

`examples/wasm-repl/demo.lisp`:

```lisp
(js:call "console.log" "hello")
(js:call "Date.now")
```

The first form's request is `{"function":"console.log","arguments":["hello"]}`.
The host looks up `globalThis.console`, calls its `log` with `this` set
to `console` and the argument `"hello"`, which prints `hello`, and
replies `null`, since `console.log` returns `undefined`. The form
returns NIL.

The second form's request is `{"function":"Date.now","arguments":[]}`.
The host replies with the milliseconds since 1970 as a JSON number, such
as `1761609600000`, and the form returns that integer, which fits in a
fixnum.

## Out of scope

- JavaScript objects passed by reference. Every value is copied as JSON,
  so a DOM node or a function cannot cross.
- Calls from JavaScript into Lisp other than through `zisp_eval`.
- Promises. A function that returns one gives back `{}` after
  `JSON.stringify`, which is an empty association list.
- The `wasm32-wasi` build, whose host is a WASI runtime rather than a
  page.
