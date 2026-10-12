# Repository guidance

These instructions apply throughout this repository. Follow the user's explicit
instructions first, then any more specific `AGENTS.md` in the directory being
changed. Keep changes within the requested scope and preserve unrelated work.

## Project and source map

Silly is a Lua server framework with coroutine-based networking and a C runtime.
Use the implementation, its Lua annotations, and the matching local API reference
to establish behavior before changing it. If they disagree, resolve the mismatch
and update the affected documentation rather than copying a stale example.

| Path | Purpose |
| --- | --- |
| `src/` | Engine, worker, socket, timer, logging and platform implementations |
| `luaclib-src/` | C extensions, including HTTP/HPACK in `lhttp.c` |
| `lualib/silly/` | Runtime and Lua modules: `net`, `sync`, `adt`, `store`, etc. |
| `lualib/types/silly/` | Complementary LuaLS declarations for native modules |
| `test/` | Module suites and shared `testaux` helpers |
| `test/conformance/` | Lua protocol assertions paired with the Go harness |
| `docs/src/en/`, `docs/src/` | English and Chinese documentation |
| `deps/` | Dependencies; avoid editing vendored code for local fixes |

## Build and validation

Use `deps/lua/lua` for scripts that need only Lua. Use `./silly` for scripts that
require the runtime, coroutines, networking or native Silly modules. This project
uses its bundled Lua version; do not substitute the system Lua for validation.

```sh
make                              # Normal build; OpenSSL is enabled by default
make OPENSSL=OFF                   # Build without TLS
make test                         # Test build: SILLY_TEST, sanitizers on Unix, Snappy
make testall                      # Test build followed by the full runner
./silly test/test.lua --set=testhttp2
./silly test/test.lua --set=testhttp2 --case="Completed response"
sh test/test.sh --set=conformance/testhttp2
sh test/test.sh -j                 # Parallel runner; observe shared-port constraints
```

- Initialize missing dependencies with `git submodule update --init --recursive`.
- Build with `TEST=ON` for suites using `test.aux.c.debugctrl` or HPACK debug APIs.
  A normal binary lacks these hooks; that is a build mismatch, not a test failure.
- Build flags are not tracked as Make dependencies. Use a clean or separate build
  when changing sanitizer, allocator, OpenSSL or test flags; do not mix artifacts.
- `make clean` removes build artifacts; `make cleanall` also removes dependencies.
  Use the narrower operation that is needed. Format only changed C files with the
  repository's `.clang-format`; `make fmt` formats many files.
- Run focused regression tests first, then affected module and integration suites.
  For C memory/lifetime changes, use ASan/UBSan and leak checks where supported.
  Report what actually ran, including required external services and limitations.
- For Go harness changes, run `go build -o ../conformance .`, `go test ./...` and
  `go vet ./...` from `test/conformance/go`. Preserve the Go version supported by
  `.github/workflows/ci.yml` and `go.mod`; a newer local SDK does not justify
  raising the dependency/toolchain requirement.

## Regression tests and synchronization

- Prefer a failing regression on the original implementation before fixing a bug.
  Show the observable error, wrong value or protocol violation; another
  implementation accepting a frame does not prove that frame meets the RFC.
- Keep one module's native tests in its existing suite: HTTP/2 in
  `test/testhttp2.lua`, HPACK in `test/testhpack.lua`. Keep Go pairing assertions in
  `test/conformance/testhttp2.lua`. Reuse `test/testaux.lua` for shared helpers.
- Wrap new cases in `testaux.case` with descriptive names. Match the suite's
  assertion naming; use `Test X.Y:` in numbered suites. Include useful failure
  messages rather than imposing numbering on every descriptive regression.
- **Do not add synchronization using `time.sleep`, `sleep(0)`, polling, or an
  assumed duration.** Prefer `silly.sync.channel`, `waitgroup`, or `mutex`.
  Preserve the existing 500 ms shutdown grace in `test/test.lua` and existing
  cluster synchronization; these are explicit exceptions requested by the user.
  Signal actual milestones: a handler arriving, a writer blocking, a frame being
  processed, a peer finishing, or a connection closing.
- `channel` supports multiple producers and one waiting consumer. It rejects
  `nil` and `false` payloads; use `true` or a result table. Use separate channels
  for separate consumers/milestones.
- `waitgroup:fork` logs child errors. Ensure a child failure reaches the test's
  assertions or result channel; task completion alone is not proof of success.
- Use bounded waits such as `testaux.await`. A deadline detects a missing event;
  it must not act as the event that makes the test pass. Timers may supply actual
  test input for inactivity/deadline behavior (`testaux.elapse`), with completion
  still established through protocol events or synchronization primitives.
- Close streams, clients, listeners and peers, cancel timers, and wait for the
  relevant tasks/readers to finish. A socket command barrier does not wait for
  peer EOF, write draining or protocol cleanup, so it cannot replace the common
  runner's shutdown grace.
- Raw-frame tests must preserve frame ordering and read buffered output before
  closing peers. Avoid running suites with overlapping listening ports together.

## Coroutine and timer invariants

The engine has a Lua worker, a socket thread, a timer thread and a monitor; Hive
adds worker VMs. Lua business code is cooperative, but shared state can change
across a yield. Single-threaded Lua does not eliminate lifecycle races.

### Event Loop Ordering

`src/worker.c` runs `task._dispatch_wakeup()` after each dispatched message; the
ready queue drains before the next message. `task.wakeup` queues a task rather
than running it inline. `time.after` callbacks execute as tasks when EXPIRE is
dispatched; `time.cancel` removes the callback and its user data. An already
queued EXPIRE is harmless if cancellation occurs before its dispatch. Cancellation
does not stop a callback that has already started.

Do not infer yield behavior solely from a function's name:

- `task.wait`, blocked reads, connection/handshake setup, listener/bind setup,
  exhausted HTTP/2 flow-control writes, full `openstream`, and contended sync
  operations can yield. `channel:pop` yields only if no result is available.
- `task.fork`, `task.wakeup`, `time.after` and `time.cancel` do not suspend the
  caller. Transport writes enqueue output; protocol wrappers may also wait.
- Check every called implementation when reasoning about a critical sequence.
  Internal task methods prefixed `_` are not public application APIs.

Before waking a waiter, detach it and finish the associated state changes:

```lua
local co = s.co
s.co = nil
s.delim = nil
if co then task.wakeup(co, result) end
```

Timeout, success, reset, EOF and close paths must compete for the same waiter
ownership and resolve it once. Use a unique timeout sentinel, guard a timer
callback against an already-detached waiter, and cancel its timer on completion.
Keep registration and wait in a sequence that cannot lose a wakeup. Never
swallow a failed yield and continue as if task state were still valid.

## API and error contracts

- Preserve established public names and signatures. For new APIs follow
  `CONTRIBUTING.md`: short lowercase names, `new` for objects with methods and
  `create` for plain data. Do not rename existing APIs/options just for style.
- Match surrounding Lua indentation, annotations and module conventions. Changes
  to signatures, defaults, units or errors require matching API docs/type stubs.
- Only `silly.net`, `silly.net.tcp`, `silly.net.tls` and `silly.net.udp` may expose
  an error contract annotated `silly.errno?`. Callers of those APIs may compare
  their errors with `silly.errno` constants.
- All higher-level modules, including HTTP, WebSocket, gRPC, cluster, DNS, storage
  and sync, expose `string?` errors. Treat these as opaque strings; do not branch
  on `errno.X` merely because an underlying transport passed that value through.
  Any layer may produce/pass through an errno internally without widening its
  public contract. White-box assertions must explicitly identify that exception.
- A normal peer close at the transport boundary reports `errno.EOF`, not `nil`.
  Log an error or propagate it at the lowest layer; avoid duplicate logging unless
  that layer supplies necessary context or cannot propagate the failure.
- During `pairs` traversal, removing an existing key is supported; adding a new
  key is not. Defer insertions until after the traversal.

## Protocol and C changes

- Check the applicable RFC and the actual peer implementation. HTTP/2 and HPACK
  follow RFC 9113 and RFC 7541; Go HTTP/2 options are not grpc-go options. Identify
  client versus server settings and units explicitly.
- Keep connection and stream state, windows, HPACK send/receive tables and error
  scope distinct. Control frames must bypass DATA flow control; HEADERS and its
  CONTINUATION frames must stay contiguous. Review normal, malformed, EOF,
  timeout, reset and graceful-close paths together.
- Preserve externally sourced algorithms unless a failing case demonstrates the
  defect. In particular, do not rewrite the Java-derived Huffman/node logic for
  stylistic reasons. Prove an HPACK change with wire bytes and decoded fields;
  distinguish defects in the old implementation from added stricter validation.
- C extensions use the Lua stack and resource ownership rules. Recursive helpers
  share the initial stack allocation: reserve additional slots with
  `lua_checkstack`/`luaL_checkstack` before pushing. Use a cleanup-capable failure
  path when non-GC resources exist; a Lua error can bypass ordinary C cleanup.
- Validate lengths and integer bounds before allocation, indexing, shifts and
  wire decoding. Preserve stack balance and cleanup on all exits.
- `src/platform.h` is for engine code, not extension portability. For extensions,
  use the necessary platform header selection locally and keep platform logic in
  the existing `src/unix`/`src/win` abstractions where applicable.

## Documentation, changelog and commits

- For behavior/API changes, update the English and Chinese reference pages and
  relevant annotations/type stubs. Keep examples executable against the current
  implementation. Prefer local references over remembered APIs.
- Maintain **one consolidated `## Unreleased`** in `CHANGELOG.md`. Merge changes
  to an unreleased feature into its existing entry; describe its final behavior
  rather than listing intermediate implementation mistakes or commits.
- Use `Added` for new capabilities and `Changed` for revised existing behavior.
  Use `Fixed` **only for a defect present in a published release**. Verify that
  against release tags/history; fixing a feature introduced since the last
  release belongs with that feature's `Added`/`Changed` entry. Leave published
  version entries unchanged. Test-only edits need no standalone release note
  unless they introduce a useful testing capability.
- Match recent commit subjects (`h2:`, `http2:`, `tests:`, `docs:`, etc.). Describe
  the final change and meaningful validation; do not include abandoned plans.
  Run `git diff --check` and inspect the staged diff before committing/amending.
  Follow the requested history operation and preserve the author's identity;
  when current timestamps are requested, set both author and committer dates.

## Local reference index

Paths below are relative to `docs/src/en/reference/`; Chinese equivalents are in
`docs/src/reference/`. Annotations live alongside Lua implementations and under
`lualib/types/silly/` for native APIs.

| Area | Reference |
| --- | --- |
| Runtime | `silly.md`, `task.md`, `time.md`, `logger.md`, `env.md`, `signal.md`, `trace.md`, `errno.md` |
| Network | `net.md`, `net/{tcp,tls,udp,http,url,websocket,grpc,cluster,dns,addr}.md` |
| Synchronization / ADTs | `sync/{channel,mutex,waitgroup,singleflight}.md`, `adt/{buffer,queue,list}.md` |
| Storage | `store/{mysql,redis,etcd}.md` |
| Crypto / encoding | `crypto/{cipher,hash,hmac,pkey}.md`, `encoding/{base64,json}.md`, `security/jwt.md` |
| Metrics / tools | `metrics/`, `console.md`, `debugger.md`, `hive.md`, `patch.md`, `perf.md` |

Tutorials are under `docs/src/en/tutorials/` and `docs/src/tutorials/`. Check
`./silly --help` for CLI options and `.github/workflows/ci.yml` for CI setup.
