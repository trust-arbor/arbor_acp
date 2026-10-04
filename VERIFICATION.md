# Extraction verification

Source snapshot: `1808c56bd4fc7b000043c2775f61ecced6ed059f` from current main ExMCP. The local sibling extraction's initial Git history is preserved; its stale source copies were replaced. Original sibling and dirty cutover spike were untouched.

Each project is independently publishable as version `2.0.0-dev`. `arbor_acp` has no vendor runtime modules; `arbor_acp_adapters` is optional. Pure JSON-RPC, byte framing, environment isolation, stdio byte handling, log summaries, and line buffering live only in `arbor_rpc`. Core adapter support owns name/value validation, workspace authorization, and adapter policy over shared subprocess handles. Vendor session and credential policy belongs to the bundle via the optional generic `Adapter.environment_defaults/1` callback, layered before `env/1` and caller overrides.

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

## Shared subprocess API checkpoint

Commit `8ca3803` on `codex/shared-subprocess` adds the neutral
`Arbor.RPC.Subprocess` actor and `Arbor.RPC.FramedStream`; existing ACP/MCP/Pi
wrappers were not yet rewired in that commit. The API uses a stable Port owner, an opaque
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

Commit `d9407b9` is the tested shared ABI basis for the wrapper adoption below.
It adds `Subprocess.os_pid/1` without exposing private actor state and fixes
minimum/current formatter drift. The full RPC suite passes 65 tests on both
Elixir 1.17.3 / OTP 27.0.1 and Elixir 1.19.5 / OTP 28.4.1. Both formatter checks
pass. The first PR minimum failure was formatting before tests, rather than a
runtime failure; the follow-up commit corrects it.

## ACP adapter wrapper integration

Adapter support now applies ACP environment policy over the reviewed RPC API;
it opens an opaque handle and subscribes the lifetime owner with one frame of
credit. The persistent bridge monitors the actor and validates each generation,
translates native frames, and acknowledges after bounded outbox admission.
Managed adapters provide a pure optional `subprocess_receipt/2`, captured before
translation can replace the handle. Known cleanup failures propagate through
`Adapter.shutdown/1` result tuples and `AdapterBridge.close/1`. Finite bridge
receive deadlines include caller/actor mailbox delay; expired readers cannot
consume previously buffered output. Public extension changes are documented in
`docs/ADAPTER_EXTENSION_API.md`.

Pi managed sessions use the same owned actors and frame credit, monitor abrupt
actor death, and translate EOF remainder before failing pending work. Its
unmanaged callback input uses the shared bounded framing decoder. Startup
banners have aggregate count/byte limits. Rejected queued-prompt writes preserve
the prior settled response and fail the new pending prompt explicitly. Known
cleanup failure, including a terminal error from an already-stopped actor,
prevents replacing the child or deleting session storage.
The golden harness uses opaque owned handles for native outbound echo, while
the new subprocess tests exercise actual actor input/delivery. No golden fixture
was regenerated or modified.

Under the private current toolchain:

- RPC: 65 tests, zero failures.
- Core alone: 338 tests, zero failures, seven excluded SDK/ecosystem cases.
- Adapter bundle: 1,447 executed tests, zero failures, four excluded CLI cases.
- Pinned official SDK interoperability: six tests, zero failures.
- Independent production builds pass with warnings as errors; source ownership
  and Git whitespace checks pass.
- All three projects pass both minimum and current formatter checks.
- Real Hex archive builds succeed with local overrides absent. Nested contents
  and dependency metadata contain no tests, caches or host paths; the core
  archive contains no vendor runtime code.
- Minimum adapter suite: the same 1,447 executed tests, zero failures (Elixir
  1.17 reports 1,451 total tests including the four exclusions). The minimum
  core suite passes the same 338 executed tests with zero failures (345 total
  including seven exclusions).

This qualifies adapter-wrapper adoption rather than completing the shared
subprocess release gate. Native ACP child stdio adoption is the next scope;
raw Port inbox pressure, Windows cleanup, global logger lifecycle and full
runtime/scheduler convergence remain open.

## Absolute deadline read addition

`FramedStream.next_until(handle, deadline, opts \\ [])` is additive to the
qualified ABI. Normal finite reads retain the original monotonic cutoff across
protocol-filter retries and never become fresh zero polls after expiry.
`buffered_only: true` retains the original explicit poll cutoff while granting
each attempt a finite scheduling lease; frames queued after the original cutoff
remain available. Existing `next/2` semantics are unchanged.

The full RPC suite passes 68 tests with zero failures on both private minimum
and current toolchains, including a filter retry past deadline, a suspended
actor with a persistent expired reader, and a later queued frame excluded by an
original zero poll. Both formatters, production warnings-as-errors, source
boundaries, whitespace and the real RPC archive build pass.

## Fast-child PID retention

Shared mechanics revision `62c006001ac98eed493f743718c1bbf282fbd273` opens
the resolved executable directly with OTP's `:eof` option. This retains owned
PID metadata after a very fast exit without changing environment, argv or
stdin, introducing a launcher or replaying the command. Only a delivered
`exit_status` proves the direct child died; EOF from a live child does not.
Failed group startup avoids signalling an already-reaped fallback PID and
reports unconfirmed cleanup separately from its original ownership-proof error.

The RPC suite passes 74 tests with zero failures on both toolchains. New
regressions cover 20 fast executions and their complete/unfinished output,
exact argv and initial stdin, exact environment additions/removals under both
policies, shell startup-file isolation, live stdout closure, a retained stale
PID after failed group proof and immediate lifetime-owner shutdown. Both
formatters, production warnings-as-errors, boundaries, whitespace and a real
16-file RPC Hex archive pass.

## Native ACP child stdio integration

Native ACP child stdio now uses the shared actor and exact absolute deadline
API from `62c006001ac98eed493f743718c1bbf282fbd273`. Its old Port ownership,
executable fallback, buffering and TERM/KILL implementations have been removed.
Native agent IO-device stdio is a separate transport and remains in ACP core.
Outbound ACP validation and BOM/noise/UTF-8 policy remain protocol-owned.
Direct push subscribers use neutral generation-tagged events with explicit
credit; the built-in client keeps its existing one-message pull handoff waiting
for processing ACK. The client monitors abrupt actor death, closes after
receiver failure, and preserves known cleanup errors through disconnect and
failed initialization. Custom close exceptions/invalid returns are explicit
errors, and adapter transport no longer hides every close-call exit.

Native integration qualification: both minimum and current core 352 executed
tests / zero failures, seven exclusions (minimum ExUnit reports 359 total);
both minimum and current bundle 1,447 executed / zero failures, four exclusions
(minimum ExUnit reports 1,451 total);
official SDK six / zero failures. The RPC ABI is qualified at 74 tests on
both toolchains. Native protocol tests cover temporary openers/readers, exact
per-frame limits over aggregate chunks, BOM/banner filtering, slow partial
timeouts, invalid UTF-8, pressure, child PATH denial, direct push credit, actor
death, native initialize/disconnect and known/unconfirmed cleanup failures.

Current and minimum format checks, production warnings-as-errors compilation,
source-boundary checks and whitespace checks pass. The real core Hex archive
contains 39 files with ordinary Hex dependency metadata; it contains no vendor
code, tests, dependency caches, temporary source paths or absolute host paths.

## Remaining v2 gates

Vendor utility commands still need the shared bounded command-capture path:
`ClaudeSdk` authentication logout (`claude_sdk.ex`), Pi startup probes
(`pi/startup.ex`) and Git worktree discovery (`claude_sdk/session_store.ex`).
Their command selection, output interpretation and vendor policy remain adapter
responsibilities. The current native/adapter transport convergence does not
qualify these utility commands or the entire subprocess release gate.

Fast group startup remains conservative: if the owned group leader exits before
its PGID can be measured, startup returns `:child_not_process_group_leader`.
No unverified group is signalled. Supporting this group case and broader
platform/pressure qualification remain separate release gates.

- Accepted namespaces are `Arbor.ACP.*` and `Arbor.RPC.*`. This checkpoint keeps existing `lib/arbor_acp`, `lib/arbor_rpc`, and matching test paths; directory depth is an implementation detail. Full consumer migration documentation remains a release gate.
- Adapter support, persistent bridges, Pi managed sessions and native ACP child stdio now share subprocess ownership and bounded delivery. Shared raw-input pressure/platform qualification and global stdio logger lifecycle remain open.
- Full runtime/scheduler redesign and the accepted full v2 protocol/API scope remain release gates.
- Documentation generation, clean Hex dependency consumer installation, live credential-free ecosystem smoke, and broader cross-runtime interop remain release checks. The local workspace path checks do not establish those outcomes.
- The public trust-arbor/arbor_acp destination was created and origin points there. The tested extraction and accepted namespace migration are pushed to `main` at `06d153f0bcb515f132b3ab7b439f9b21b503868c`; no package has been published or release tag created.

Legacy wire `_meta.ex_mcp`, generated native request IDs, client information defaults, and Pi's `~/.ex_mcp/pi/session-map.json` location are intentionally preserved for compatibility.
