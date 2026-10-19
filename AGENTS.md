# Repository guidance

Follow explicit user instructions first, then more specific `AGENTS.md` files.
Inspect the branch and working tree before editing. Preserve unrelated work and
keep changes within the requested scope, including when using linked worktrees.

## Project and reference map

Silly is a Lua server framework with coroutine-based networking and a C runtime.
Establish behavior from the implementation, Lua annotations and matching local
API reference; resolve discrepancies rather than copying stale examples.

- `src/`: runtime, sockets, timers, workers and platform abstractions.
- `luaclib-src/`: native extensions; HTTP/2 and HPACK live in `lhttp.c`.
- `lualib/silly/`: Lua modules; `lualib/types/silly/`: native API declarations.
- `test/`: native module suites; `test/conformance/`: Lua/Go protocol comparisons.
- `docs/src/en/reference/` and `docs/src/reference/`: English and Chinese APIs;
  the corresponding `tutorials/` directories contain examples.
- `deps/`: vendored dependencies; avoid unrelated edits here.

## Resource limits and validation

This server has limited memory. Default to serial builds and test suites:

```sh
make -j1
make -j1 test                         # TEST=ON and Snappy; sanitizers on Unix
./silly test/test.lua --set=testhttp2
./silly test/test.lua --set=testhttp2 --case="^Test 37:"
sh test/test.sh --set=conformance/testhttp2
```

- Do not use unbounded build/test parallelism or start competing builds. For Go,
  use `GOMAXPROCS=2` and `-p=1`; keep suites with shared ports sequential.
- Use bundled `deps/lua/lua` for pure Lua scripts; use `./silly` for runtime,
  coroutine, networking and native-module tests. Do not substitute system Lua.
- Initialize missing dependencies with `git submodule update --init --recursive`.
  Suites using `test.aux.c.debugctrl` or HPACK debug APIs need `TEST=ON`.
- Build flags are not tracked as Make dependencies. Use a clean or isolated build
  when changing sanitizer, allocator, OpenSSL or test flags. Prefer `make clean`
  to `make cleanall`; the latter also removes dependencies.
- Run affected module/integration suites; use ASan/UBSan and leak checks for C
  memory or lifetime changes. Broaden or repeat verification when new changes,
  failures or unresolved concerns warrant it.
- For Go harness changes, run `go build -p=1 -o ../conformance .`,
  `go test -p=1 ./...` and `go vet -p=1 ./...` from `test/conformance/go`.
  Preserve the Go/dependency versions supported by CI and `go.mod`.
- Report actual results, including failed/skipped suites and environmental
  limits. A passing run with a temporary test workaround must identify it;
  do not describe that as an unmodified full-suite pass.
- Fetch large CI logs with `gh` into local files. Inspect job conclusions and
  narrow failure/stack/tail excerpts instead of dumping complete logs.

## Implementation style

- Preserve existing APIs. New exported functions use at most two lowercase words
  without underscores; parameters and members may use underscores. Follow
  `CONTRIBUTING.md`: `new` creates objects, `create` creates plain data.
- Match surrounding indentation and block layout. No one-line Lua `if` statements
  or semicolons joining statements. Keep related macros and declarations uniform.
- Aim for roughly 100 columns. Prefer readable expressions to artificial wrapping;
  a small overrun is acceptable when clearer. Format only changed C code using
  the repository style; `make fmt` touches many files.
- Put C declarations at the start of their scope. Avoid function calls inside a
  declaration block except at its end, without adding artificial scopes to comply.
- Use `local pcall = silly.pcall` with the other aliases for protected calls with
  the project's traceback formatting. Use a custom wrapper only when needed.
- Factor shared conditions. Remove needless repeated lookups, joins, conversions
  and temporary objects when straightforward, while preserving DRY and clarity.
  Measure uncertain optimizations; do not trade proven code for speculative speed.
- Do not add tiny forwarding helpers without useful abstraction. Maintain accurate
  LuaLS annotations when fields, return values or ownership change.

## Regression tests and synchronization

- Write or reuse a failing regression before fixing a bug. Prove the observable
  failure; another implementation accepting bytes does not establish RFC validity.
- Keep one native suite per module: HTTP/2 in `test/testhttp2.lua`, HPACK in
  `test/testhpack.lua`. Go comparisons belong in the corresponding
  `test/conformance/testhttp2.lua` or `test/conformance/testhpack.lua` suite.
- Preserve existing test numbers and gaps. Append cases using `Test N:` or
  `Test N.M:` and wrap them in `testaux.case` so `--case` can select them. If a
  case moves, retain its number and add a reference at its former location.
- Never introduce sleep, polling or assumed delays for test synchronization.
  Prefer `silly.sync.channel`, `waitgroup` and `mutex`, or protocol milestones.
  Preserve the explicit 500 ms teardown grace in `test/test.lua` and existing
  cluster synchronization; do not replace that grace with a command barrier.
- A deadline detects a missing event; it must not make the test pass. Use
  `testaux.await` for bounded event waits. `testaux.elapse` is appropriate only
  when elapsed time itself is test input, such as inactivity or timeout behavior.
- Channels allow multiple producers and one waiting consumer, and reject nil/false
  payloads. Use true/result tables and separate channels for separate consumers.
  Propagate child failures to assertions; `waitgroup:fork` logging alone is insufficient.
- Close streams, clients, listeners and peers; cancel timers and wait for relevant
  readers/tasks to finish. Closing a listener queues socket closure: do not
  immediately rebind the same fixed port for consecutive fixtures. Use distinct
  fixture ports or an actual completion event, without adding a sleep.
- Keep header blocks contiguous and drain expected peer output before closing raw
  protocol peers. Prefer the existing Go peer and standard-library protocol tools
  to a large Lua peer class; reuse `test/testaux.lua` for small shared helpers.

## Coroutine and resource invariants

Lua business code is cooperative, but state can change across a yield. Hive also
has worker VMs. Single-threaded Lua does not eliminate lifecycle races.

- `src/worker.c` drains task wakeups after each dispatched message. `task.wakeup`
  queues a task rather than running it inline.
- Blocked reads, connection/handshake setup, request admission, exhausted write
  windows and contended synchronization can yield. Check called implementations
  rather than inferring this from function names.
- `task.fork`, `task.wakeup`, `time.after` and `time.cancel` do not yield.
  Transport writes enqueue output; higher-level writes may wait for flow control.
- Timer callbacks execute as tasks. Cancellation before EXPIRE dispatch is safe;
  cancellation cannot stop a callback that already started. `time.after` clamps
  negative delays to zero and dispatches callbacks asynchronously, including at
  zero delay; do not add redundant clamps.
- Detach waiters and finish state changes before waking them. Timeout, success,
  reset, EOF and close must compete for the same waiter ownership and resolve it
  once. Keep registration and wait together so no wakeup can be lost.
- Do not swallow failed waits/yields or treat internal task methods as public APIs.
- Clear pending data and queue membership consistently. Close failed streams before
  dropping or replacing their references; a reset does not imply owner cleanup.
- Keep channel health timers separate from stream read deadlines. Avoid multiple
  timers for one state machine and unnecessary cancellation/rescheduling.

## Error and protocol contracts

- Public errors are annotated `silly.errno?` in `silly.net` and
  `silly.net.{tcp,tls,udp}`, and opaque `string?` in higher-level APIs. Transport
  errors may pass through; errno comparisons in higher-level tests are white-box
  checks, not part of those APIs' error contracts.
- Compare symbolic errno constants, never platform-specific numbers. Normal peer
  closure at the transport boundary reports `errno.EOF`. Propagate or log at the
  lowest appropriate layer and avoid duplicate logging.
- Check RFC 9113/7541 and actual peer behavior for HTTP/2/HPACK work. Go HTTP/2
  options differ from grpc-go options; verify client/server scope and units.
- Distinguish connection/stream state, send/receive windows and HPACK tables, and
  stream/connection error scope. Control frames bypass DATA flow control;
  HEADERS/CONTINUATION must stay contiguous. Review malformed input, EOF, timeout,
  reset, normal completion and graceful shutdown together.
- Preserve externally sourced algorithms, including the Java-derived Huffman/node
  logic, unless a failing case proves a defect. Check HPACK with wire fixtures,
  decoded fields and cross-decoding; distinguish old bugs from stricter validation.
- Validate lengths and bounds before allocation, narrowing, shifts or indexing.
  Preserve Lua stack balance and resource ownership; recursive helpers must reserve
  stack space, and Lua errors can bypass ordinary non-GC cleanup.
- Keep engine platform code in `src/unix`/`src/win`. Native extensions should not
  depend on engine-only `src/platform.h` for portability.
- Removing existing keys while traversing `pairs` is supported; defer new keys.

## Documentation and changelog

- Update both language references and annotations for API/behavior changes. Keep
  examples executable and prefer local documentation to recalled signatures.
- Maintain one consolidated `## Unreleased`. Merge revisions of unreleased work
  into its existing entry; do not record the sequence of implementation attempts.
- `Added` describes new capabilities. `Changed` describes API or observable behavior,
  not implementation details. Use `Fixed` only for defects in a published release,
  verified against tags/history. Leave published entries unchanged.
- Keep release notes short. Documentation and `AGENTS.md` edits need no changelog
  entry; test-only corrections generally do not need one either.

## Git commits and history

- Follow repository subjects: `component: imperative summary`. Identify the concrete
  problem/behavior; for bugs, prefer e.g. `etcd: fix keepalive stream leak on reconnect`.
- Explain why the change is needed, then how it addresses the problem. For fixes,
  describe the trigger, cause and user-visible impact. Prefer a short prose body;
  change size alone does not justify a list. Use bullets only when distinct points
  are clearer that way.
- Do not repeat the diff or routinely list tests, documentation and housekeeping.
  Include those details only when they explain the change. Omit obvious concluding
  fix paragraphs, conversational history, abandoned approaches and generic claims.
- Add `Fixes:` only when the introducing commit is verified and the repository or
  user calls for it. Do not invent commit references or review/test endorsements.

Example:

```text
http2: detect unresponsive peers with PING

Idle connections can remain open after the peer becomes unreachable.
Allow HTTP and gRPC clients to send PING probes after a receive-idle
interval and close the connection if the acknowledgement times out.
```

- Inspect the staged diff and run `git diff --check` before committing. Stage only
  the intended files/hunks. When the user requests message review, show the complete
  message and wait for confirmation before creating that commit.
- Follow requested splitting/squashing. Keep commits independently buildable and
  avoid knowingly failing intermediate commits; combine dependent corrections when
  requested. Verify a history-only squash preserves the final tree. After rebasing
  onto a new base, verify the intended changes and conflict resolutions against it.
- Preserve author identity and the current branch's timestamp policy. For an amend
  with fixed times, capture author and committer dates separately and restore each;
  do not silently replace either with the current time. If current time is requested,
  capture one instant for both. Keep transient timestamp values out of this file.
- Push only when authorized. After an authorized history rewrite, use an explicit
  `--force-with-lease`, and verify the remote head. Do not alter unrelated branches.

## Pull request wording and notifications

**Before creating a PR or changing its title/body, show the user the complete
proposed title and body and obtain confirmation, including for each later edit.**
These writes can send email; finish drafting before writing to GitHub.

- Lead with the problem and resulting behavior. Keep the title and body concise;
  use a few bullets only when they add distinct information. Avoid detailed internal
  mechanics, work logs, abandoned plans and copied commit-log dumps.
- Use `Validation:` for relevant checks that actually ran. State material test
  limitations accurately; do not call partial or workaround-assisted runs full passes.
- Approval to commit, amend or push does not authorize creating/opening/closing a
  PR or editing its title/body. A branch push may update an existing PR without
  rewriting its description.
- After text approval, write that exact text once, using `gh` with `--body-file`
  or a structured argument to preserve newlines. Verify the result read-only.
- Report new CI results in chat. Do not post progress comments or other
  notification-triggering messages unless asked.
