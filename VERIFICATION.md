# Extraction verification

Current version preparation: ACP and Adapters `1.0.0-rc.1`, consuming RPC
`1.0.0-rc.1`. The original four 2.0.0-rc.1 packages are published. Replacements
are unpublished and require fresh metadata/archive qualification. The dated
extraction checks below retain their original versions and source identities.

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

## Bounded utility capture (2026-10-04)

The working utility slice is based on `25fc8d14d346b3fbe8a53a40ac4d8b3fa7605e54`.
`Arbor.RPC.Subprocess.capture/2` captures a finite command with the caller as its
lifetime owner, one monotonic read deadline and a total output-byte cap. Defaults
are 5 seconds / 1 MiB. LF, CR, blank lines, arbitrary bytes and unfinished EOF
output count toward the cap and are preserved. Nonzero status remains
`{:ok, output, status}` for the caller to interpret. Byte overflow normalizes the
actor's frame/chunk/queue-byte reasons to `:output_too_large`; count/mailbox
pressure remains explicit. Known cleanup failure takes precedence and includes
the original capture result reason. Cleanup follows read expiry with its own
finite budget and up to 1 second of actor-call allowance.
On unconfirmed close, capture force-stops only its freshly opened actor; its
guardian attempts bounded OS cleanup while the caller can remain alive. The
original cleanup failure remains explicit.

`AdapterSupport.Subprocess.capture/4` applies the existing adapter defaults,
`env/1`, explicit overrides, isolated child PATH/cwd and stderr policy. Claude
logout, Pi version/npm probes and Claude Git worktree discovery now use this
path. Logout defaults to 5 seconds / 64 KiB; each Pi probe uses 800 ms / 64 KiB;
worktree discovery uses 1 second / 1 MiB. Optional metadata probes omit results
on failure. Both Pi probes and worktree discovery retain caller environment
policy, including effective PATH and cwd. Golden transcripts were not changed.

On macOS, independent Elixir 1.19.5 / OTP 28.4.1 and minimum Elixir 1.17.3 /
OTP 27.0.1 source/dependency copies pass the complete suites: RPC 87, core 355
executed (+7 excluded), adapters 1,454 executed (+4 excluded), zero failures.
Minimum ExUnit includes exclusions in its displayed totals (362 / 1,458).
New capture tests cover exact bytes and argv, CR/LF across chunks, nonzero status,
overflow, one absolute deadline, closed stdout with a live child, caller death,
explicit environment/unsets/isolation, child PATH denial, finite validation,
frame-count pressure and a suspended actor's known cleanup-call timeout. That
regression proves actor death and actual child cleanup without resuming the
actor or ending its capturing owner's lifetime. Core
and vendor utility tests cover adapter precedence, real command cleanup,
logout status/error text, Pi optional failures and mapped worktree options.

Both toolchains pass production warnings-as-errors compilation, complete
formatter and package source-boundary checks. An independent Elixir 1.20.3 /
OTP 29.0.5 copy also passes all 87 RPC tests, production warnings-as-errors
compilation, formatting and workspace package boundaries.

Six real Hex archives (three packages on each minimum/current toolchain) have
identical checksums across toolchains: RPC contains 17 files, core 39, adapters
41. Default metadata uses ordinary Hex Jason/Telemetry and `~> 2.0.0-dev`
internal requirements. Archives contain no tests, caches, local dependency paths
or absolute host paths; the core archive has no vendor implementation. These
local archive checks do not establish installation from the unpublished Hex
dependencies.

Shared process-group ownership and
fast group startup limits still apply. OTP driver input can accumulate before
the actor checks its mailbox; managed counters do not imply a hard raw-driver or
total-memory bound. This utility checkpoint does not qualify the whole
subprocess platform/pressure matrix or complete the full runtime scope.

Neutral close now validates the local actor's proc-lib identity and private
generation marker. On timeout it rechecks that identity before force-stopping
the matching actor, preserving `{:error, :timeout}`. A real suspended-actor
regression proves live-child reaping; stale generations and an unrelated process
with a copied marker cannot trigger signalling. No generic abort API is added.
The guardian after hard actor death has only captured PID/group proof and calls
`Cleanup.run(proof, nil, ...)`; it has no retained Port or actual `exit_status`.
Actor DOWN does not confirm its cleanup, and the retained-Port stale-PID test
qualifies only live-actor cleanup. Delayed-PID-reuse safety and guardian cleanup
confirmation on the hard-death path remain explicit release gates.

## Remaining v2 gates

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

## Native cleanup in the v2 draft (October 4, 2026)

The `b46cbfe8ced0d29519462f8a83b64e5750caaa92`-based native implementation is integrated in this unpublished v2 draft and replaces the historical numeric cleanup mechanism described above. Stable releases are unchanged. See [Native subprocess cleanup draft](docs/NATIVE_SUBPROCESS_DRAFT.md) for ownership, versioned protocol, typed/finite receipt semantics, source-build installation and explicit platform gates.

The exact draft passes the complete minimum/current/newest RPC103, core355 and adapter1,454 suites with production warnings-as-errors, formatting and source boundaries. The four core intentional invalid-input fixtures retain exact exception assertions using dynamic invocation. Official ACP SDK six cases and unchanged vendor goldens pass. Ten real native protocol tests plus four post-reap syscall-invariant cases pass on macOS; no actual PID-reuse exhaustion was attempted. Current/minimum source archives and fresh package-only consumers qualify reviewed C source build, installed priv lookup and release evaluation with runtime compiler lookup disabled. Local external dependency sources replace unavailable unpublished registry dependencies in these consumer checks.

The exact source/path/verification manifests were checked during draft integration; Linux CI, broader pressure measurement, Windows Job/handle support, hard-helper-loss/uninterruptible exit, packaging selection and full v2 remain gates. No publication or stable release default change occurred.

## Package metadata and standalone documentation checkpoint (2026-10-04)

Independent metadata QA starts from ACP `cc8b2078855148f390e899c7122fa56c8275da17`
and MCP `9f47f38bc4443844c170563d8609afb38910e4a8`. The production protocol,
adapter, native C and framing source is unchanged by this slice. ExDoc is a
dev-only dependency in all three ACP projects; actual standalone WAE docs passed
on Elixir 1.17.3/OTP 27.0.1 and Elixir 1.19.5/OTP 28.4.1. Generated source links
contain package-qualified version tags and `packages/<app>/` source paths.

All four actual source archives were built with normal declared dependencies for
`2.0.0-dev`, prepared literal `2.0.0-rc.1`, and prepared literal `2.0.0`, on both
toolchains (24 source archives). Six four-package consumers compiled with
warnings-as-errors and ran both installed application and compiler-free release
probes. Their metadata/literal/.app versions, prerelease/stable ranges, package
boundaries, native capture bytes/status, retained cleanup receipts and independent
MCP/ACP lifetimes passed. Installed/release version and module inventories agree, as do native helper
bytes. Raw .app and BEAM checksums are recorded separately: release assembly
rewrites application metadata and strips BEAM debug data. The native C source ships; generated host `priv/native`
files do not. Local consumers use explicitly recorded independent external
source caches because these coordinated packages are unpublished. This does not
establish final published-Hex resolution or qualify Linux/Windows by inference.

Version matching rejects the wrong major, earlier dev snapshots beneath an RC
floor, and prereleases under the stable floor; stable accepts compatible later
2.x. Negative probes reject source/expected version mismatch, checksum corruption,
a shipped native binary, invalid/overlapping release preparation, and output
clobbering. Preparation copies use literal versions; no source version depends
on release environment variables. Source archives, code/native checksums and
raw logs are retained in the immutable metadata qualification artifact.

This is packaging evidence for the recorded source checkpoints. Final compiled
API/semantic comparison, normal Hex resolution, all supported platform/transport
gates and rebuilt archives matching the final release commits/tags remain
required. These checks perform no publication or Git tagging.
