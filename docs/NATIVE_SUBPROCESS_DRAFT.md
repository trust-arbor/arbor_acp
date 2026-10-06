# Native subprocess cleanup draft

This is the historical implementation/qualification checkpoint for the source
base below. Its pending-decision and gate notes are retained as evidence, not
current installation instructions. The implemented source-build policy and
current remaining limits live in the separate
[ArborRPC repository](https://github.com/trust-arbor/arbor_rpc#source-build-and-remaining-gates);
see the [workspace README](../README.md) for ACP setup and release status.

Status: integrated into the unpublished ACP v2 draft; stable releases are unchanged.
Source base: `b46cbfe8ced0d29519462f8a83b64e5750caaa92`.
Source-build packaging is the working assumption pending the packaging decision.
Native C source SHA-256: `e5c92784c789e9c377d5c777c79bcb898c296f5c2d8877274a878a31eea135e9`.

## Ownership and receipts

The Actor keeps existing bounded framing/deadline/consumer semantics. Guardian
owns the helper Port from launch and monitors both Actor and lifetime owner
before opening it. Native parent alone forks, observes and reaps its vendor
child. Its `SIGCHLD` disposition never auto-reaps; `waitid(WNOWAIT)` keeps even
an exited child waitable until signalling is permanently disabled. Numeric PID
metadata is diagnostic, never a caller-supplied cleanup authority.

Cleanup sends finite TERM then KILL only while the owned child remains unreaped.
Group mode verifies the private group leader after `setsid`. The parent disables
all signalling before `waitpid`. Afterwards, a bounded read-only
`kill(-original_pgid, 0)` observes targeted-group existence: ESRCH gives absence;
occupied/reused identity, EPERM, unknown result or expired budget is unconfirmed.
There are no post-reap TERM/KILL paths. Group absence does not imply containment
of descendants that escape the group/session or an arbitrary process tree.

Public `cleanup_receipt/1` returns a typed receipt with direct-child reaping,
targeted-group absence, actual vendor status, separate helper status, generation,
monotonic completion time and failure reason. Guardian retains it for finite
`:receipt_retention` (default 5 seconds), then stops. Dead Actor close consults
this receipt; known errors survive stopped-handle close. Dead/expired Guardian
returns `:cleanup_status_unavailable`. Actor DOWN alone never means OS cleanup.

Existing handles gain an internal Guardian identity. Close/receipt paths validate
private local process identity and generation. Close timeout keeps its error,
force-stops only the matching Actor, and leaves Guardian/native cleanup active.
The retired private `Cleanup.proof/3`, `run/3`, `after_exit/3` return
`:unsupported_unmanaged_cleanup`; they never signal or close a supplied Port.
Managed cleanup errors remain their specific retained result.

## Version 1 helper protocol

Carrier: OTP packet-4 framing. Every payload starts with version byte 1 and type.
Each session has a native random 64-bit token; commands have no PID/PGID field.
Wrong version, token, size, sequence, enum or inconsistent receipt shape fails
explicitly. Input and write buffers are bounded by configured `:max_write_bytes`
(maximum 64 MiB), rather than a declared unchecked packet length.

| Direction | Type | Meaning |
|---|---|---|
| Native → Guardian | S | Started child/group proof or exec/setup error |
| Native → Guardian | D | One sequenced stdout chunk, at most 16 KiB |
| Native → Guardian | O | Actual vendor exit observed, still waitable |
| Native → Guardian | F | Vendor stdout EOF |
| Native → Guardian | W | Sequenced stdin admission result |
| Native → Guardian | R | Reap/group cleanup receipt |
| Native → Guardian | E | Protocol rejection |
| Guardian → Native | A | Initial or exact sequenced data credit |
| Guardian → Native | I | Sequenced stdin bytes |
| Guardian → Native | C / Q | Begin cleanup / retire after cleanup |
| Guardian → Native | H | Renew finite owner/control lease |

One data credit permits one raw chunk. Actor returns it after bounded framing
admission; other processes cannot return credit through the ACK facade. Public
frame ACK remains after application processing. Native output uses ten bounded
packet slots with reserved terminal/control capacity. Guardian serializes one
pending native write; the Actor independently validates immutable configured
write capacity/iodata before the Port, while normal facade admission happens
before its mailbox. Arbitrary raw same-VM sends are outside managed bounds.
Busy stdin queues report `:backpressure`, and accepted
writes mean admission rather than vendor consumption.

Vendor exit, final bytes/EOF, cleanup receipt and helper exit are separate. Raw
credit can remain withheld while cleanup completes; final bytes stay collectible
after actual vendor exit. Oversized frame/chunk/queue reasons and accepted prefix
frames are preserved. Abandoned output and receipts have separate finite leases.
Kernel pipes, Port-driver allocation, application-retained bytes and arbitrary
caller write concurrency remain outside managed frame counters.

## Build/install boundary

Custom Mix compiler builds shipped `c_src/subprocess_helper.c` with a C17 compiler
on macOS/Linux; `CC` selects an executable, with fixed flags/argv and no shell
command strings. Generated `priv/native` binary/manifest are ignored and excluded
from Hex source archives. The compiler refreshes Mix application structure after
generating priv, including first installation from an archive with no priv tree.
Runtime/release lookup uses `:code.priv_dir(:arbor_rpc)` and never a source path or
runtime compiler. There is no NIF or numeric signalling fallback. Framing/JSON-RPC
use starts no helper; missing or unsupported subprocess helper fails explicitly.

## Qualification and remaining gates

On this macOS host, minimum Elixir 1.17.3/OTP 27.0.1, current 1.19.5/OTP 28.4.1 and
newest 1.20.3/OTP 29.0.5 pass complete RPC 103, core 355 (+7 exclusions), adapters
1,454 (+4 exclusions), production warnings-as-errors, formatting and source
boundaries. Minimum ExUnit prints exclusions in displayed totals. Four deliberate
nil-input protocol tests use dynamic invocation with unchanged exact exception
assertions; production specs and behavior were untouched. Official ACP SDK 1.4.0
current interoperability passes six cases; golden transcripts were unchanged.

Real-process native tests cover exact argv/env/cwd and arbitrary stdin/output,
fast unreaped exit, delayed control/repeated receipt, invalid token/target argument,
oversized commands, duplicate credit, group leader/descendants, control EOF,
withheld output credit and a finite escaped descendant. Four syscall-seam cases
prove zero signals after reap for occupied/absent/EPERM/expired identities; they do
not force actual PID reuse. BEAM tests cover owner hard death during launch,
Actor suspension/death, immutable write admission, helper/Guardian loss, bounded raw credit, responsive
cleanup, final bytes after reap, retained success/unconfirmed/expired receipts,
missing helper and counterfeit/stale handles. Existing framing, capture and
adapter suites remain part of qualification.

Six minimum/current source archives have normal version metadata, reviewed C
source, no generated helper, tests, caches, host paths or vendor code in core.
Fresh package-only consumers on both toolchains build the helper and pass exact
EOF bytes/status, retained cleanup receipts and release evaluation with compiler
lookup disabled at runtime. External Jason/Telemetry come from independent
reviewed source copies; these checks do not prove installation from unpublished
Hex registry dependencies.

Remaining release gates: Linux source-build/lifecycle/pressure CI; wider macOS
pressure/memory/write-block measurement; native helper hard death or uninterruptible
vendor cleanup (explicitly unconfirmed); packaging choice and supported compiler
matrix; Windows native handle/Job implementation (currently unsupported-safe
failure); escaped-descendant containment policy; full protocol/runtime release
qualification. Local macOS success does not establish Linux/Windows support or
completion of the complete v2 release.

Linux compilation at the first integrated checkpoint rejected three unchecked startup-pipe writes under GCC warnings-as-errors. The helper now checks each setup/error report and fails before exec when a complete report cannot be written. Fresh Linux qualification is required for this correction.
