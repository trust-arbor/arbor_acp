# Extraction verification

Source snapshot: `1808c56bd4fc7b000043c2775f61ecced6ed059f` from current main ExMCP. The local sibling extraction's initial Git history is preserved; its stale source copies were replaced. Original sibling and dirty cutover spike were untouched.

Each project is independently publishable as version `2.0.0-dev`. `arbor_acp` has no vendor runtime modules; `arbor_acp_adapters` is optional. Pure JSON-RPC, byte framing, environment isolation, stdio byte handling, log summaries, and line buffering live only in `arbor_rpc`. Core adapter support owns name/value validation, workspace authorization, and the temporary subprocess wrapper. Vendor session and credential policy belongs to the bundle via the optional generic `Adapter.environment_defaults/1` callback, layered before `env/1` and caller overrides.

## Completed checks

The accepted `Arbor.ACP.*` / `Arbor.RPC.*` migration was verified from empty package build caches with the same suite counts below. All three distinct Mix projects use the corresponding nested namespaces. Legacy metadata and storage markers were compared against the extraction commit and remained unchanged.

Toolchain: Elixir 1.19.5 / OTP 28.4.1, using a task-private Hex 2.5.1 archive compiled for that toolchain. External dependencies used the reviewed source cache through `ARBOR_V2_DEPS`; workspace dependencies used `ARBOR_V2_LOCAL=1`. The final verification tools are private to this task; a temporary mise-directed archive installation was removed.

- RPC: 34 tests, zero failures.
- ACP core by itself: 323 tests, zero failures, seven explicitly excluded ecosystem/SDK tests.
- ACP core plus adapter bundle: 1,436 tests, zero failures, four external CLI tests excluded.
- Pinned official ACP SDK 1.4.0 interoperability: six tests, zero failures. SDK peer dependency zod 4.4.3 is projected from the reviewed main lockfile. Test setup requires cached/preinstalled dependencies and does not run npm automatically.
- Native echo agent/controller example completes locally with the expected streamed text and `end_turn` result.
- All three projects compile in production mode with warnings as errors, and formatter checks pass.
- Fresh generator extraction suites pass (29 RPC primitive tests, 321 core tests, 1,434 adapter tests); independently implemented Framing and extraction regression files are preserved when regenerating an existing workspace.
- Source AST boundary checks pass: RPC cannot reference protocol modules; core cannot reference vendor modules; adapters cannot reference hidden core maps, envelope, or pending-request helpers.
- Real `mix hex.build` succeeds for all three packages with workspace/cache overrides absent. Metadata contains ordinary version requirements and no local checkout paths. Nested archive contents contain only library code, package manifest, formatter, license, README, and changelog: 11 RPC files, 39 core files, 41 adapter files. No dev tasks, tests, fixtures, cached dependencies, or vendor code enters the core archive.

The new CI workflow qualifies the advertised minimum (Elixir 1.17.3 / OTP 27) and current baseline (Elixir 1.19.5 / OTP 28) per package, verifies source boundaries, builds real manifests, and runs pinned SDK interoperability. The copied scheduled workflow preserves ACP draft-schema, catalog, and ecosystem probes with corrected workspace paths. The first GitHub package matrix and SDK lane passed on `06d153f0bcb515f132b3ab7b439f9b21b503868c`: https://github.com/trust-arbor/arbor_acp/actions/runs/37174597068. This confirms the prepared minimum/current package lanes; it does not complete the broader release gates below.

## Shared subprocess API checkpoint (local)

The `codex/shared-subprocess` working tree adds the neutral
`Arbor.RPC.Subprocess` actor and `Arbor.RPC.FramedStream`; existing ACP/MCP/Pi
wrappers have not been rewired. The API uses a stable Port owner, an opaque
generation reference, a configurable live local lifetime owner, caller-side
absolute read deadlines, monitored waiters/subscribers, and acknowledged push
credit. Queued and unacknowledged frames share count/byte caps. Streaming frame
reduction preserves accepted prefixes while reporting explicit frame/queue
overflow. Invalid or oversized writes are rejected before entering the actor
mailbox, and busy Port output returns backpressure without suspending the caller.

Explicit close stops the actor. Natural exit and pressure failure drain accepted
frames before terminal delivery and actor shutdown; abandoned drains have a
finite lease and an explicit drain-timeout event. Cleanup verifies Unix child
group leadership, isolates its utility environment, preserves permission/utility
errors as unknown liveness, reserves KILL time beyond TERM grace, and reports
cleanup failure rather than claiming an exhausted probe confirmed exit. An
independent guardian cleans the child after abrupt actor death. RPC now declares
its existing crypto runtime dependency explicitly.

Independent review regressions cover expired persistent readers, including a
zero-time poll with an already-buffered frame; temporary openers with a delegated
owner; owner, reader and subscriber death; actor hard death; TERM-ignoring
children; verified group descendants; terminal delivery and actor termination;
partial UTF-8; per-frame versus aggregate limits; in-flight accounting and stale
acknowledgements; write admission; Port backpressure; and raw input pressure.
The core's optional environment callbacks also load the adapter before probing
exports, with an unloaded first-use fixture verifying credential defaults do not
depend on test execution order.

Under the same private Elixir 1.19.5 / OTP 28.4.1 toolchain:

- RPC: 64 tests, zero failures, including 30 new subprocess/cleanup regressions.
- ACP core: 323 tests, zero failures, seven excluded ecosystem/SDK cases.
- Adapter bundle: 1,438 tests, zero failures, four excluded external CLI cases.
- Pinned official ACP SDK interoperability: six tests, zero failures.
- All three production builds pass with warnings as errors; format, source
  boundary and Git whitespace checks pass.
- Real RPC Hex build without local dependency overrides contains 16 intended
  files, ordinary Jason dependency metadata, and no host paths, tests or caches.

This checkpoint does not establish a hard aggregate Port mailbox or application
memory cap. A suspended-actor test proves that asynchronous raw driver messages
can exceed the high-water before the actor runs; processing then closes
explicitly for pressure. Concurrent writers must also be bounded by their
application. Natural group cleanup begins when the Port reports exit; descendants
holding its output pipe can delay that report. Windows cleanup, the Linux/macOS
runtime matrix and pressure qualification remain open. No protocol integration,
package publication or shared-subprocess release gate is claimed complete.

## Remaining v2 gates

- Accepted namespaces are `Arbor.ACP.*` and `Arbor.RPC.*`. This checkpoint keeps existing `lib/arbor_acp`, `lib/arbor_rpc`, and matching test paths; directory depth is an implementation detail. Full consumer migration documentation remains a release gate.
- Shared subprocess ownership, process-tree cleanup, bounded delivery queues, and global stdio logger lifecycle are not yet converged. The core subprocess helper and ACP stdio wrapper temporarily retain the current main implementation.
- Full runtime/scheduler redesign and the accepted full v2 protocol/API scope remain release gates.
- Documentation generation, clean Hex dependency consumer installation, live credential-free ecosystem smoke, and broader cross-runtime interop remain release checks. The local workspace path checks do not establish those outcomes.
- The public trust-arbor/arbor_acp destination was created and origin points there. The tested extraction and accepted namespace migration are pushed to `main` at `06d153f0bcb515f132b3ab7b439f9b21b503868c`; no package has been published or release tag created.

Legacy wire `_meta.ex_mcp`, generated native request IDs, client information defaults, and Pi's `~/.ex_mcp/pi/session-map.json` location are intentionally preserved for compatibility.
