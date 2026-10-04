# Adapter subprocess contract for v2

Custom adapters implement `Arbor.ACP.Adapter`. Native protocol translation,
request correlation, credentials and session state stay in the adapter. Generic
ACP output admission and RPC child ownership stay in their owning packages.

## Owned child support

`Arbor.ACP.AdapterSupport.Subprocess.open(command, args, opts, adapter_module)`
returns `{:ok, Arbor.RPC.Subprocess.t()}` or `{:error, reason}`. The handle is
opaque; it replaces the raw Port previously returned by this helper. Its actor
owns the Port for the child's entire lifetime. `:owner` defaults to the caller
and may name a different live local process when an opening task is temporary.

Adapter support applies the generic environment baseline (including unset
`MIX_ENV` and `MIX_TARGET`, and `TERM=dumb`), optional vendor-owned
`environment_defaults/1`, then `env/1` and explicit caller `:env`. RPC resolves
the executable against the resulting child PATH and working directory. Adapter
support defaults `:stderr_to_stdout` to true; the RPC primitive defaults it to
false. Unix `:process_group` requires a verified owned child group leader.

Support subscribes the lifetime owner with one frame of credit. Its public
operations are:

| Operation | Result |
| --- | --- |
| `command(handle, iodata)` | `:ok` or `{:error, reason}` |
| `close(handle_or_nil)` | `:ok` or a known cleanup `{:error, reason}` |
| `connected?(handle_or_nil)` | boolean |
| `identity(handle)` | opaque generation reference |
| `event(handle_or_nil, message)` | `{:frame, token, bytes}`, `{:closed, reason, remainder}`, or `:ignore` |
| `ack(handle, token)` | `:ok` or `{:error, reason}` |
| `safe_env(opts, adapter_module)` | effective Port environment tuples |

The original message is `{:arbor_rpc, generation, event}`. `event/2` ignores
old generations. Complete frames exclude LF; closure includes the original
unfinished frame bytes. An adapter decides whether to translate that remainder
before failing pending requests. `Arbor.RPC.Subprocess.linked_processes/1`
provides the stable actor PID to monitor; `os_pid/1` provides an owned child PID
for diagnostics. No Port ownership transfer or private actor-state inspection
is required.

## Managed delivery callbacks

An adapter using owned push delivery implements `handle_adapter_message/2` and
the optional **pure** callback:

```elixir
subprocess_receipt(message, adapter_state) ::
  {Arbor.RPC.Subprocess.t(), reference()} | nil
```

It identifies the matching frame receipt without acknowledging or mutating
state. The bridge captures the receipt before translation, because translation
may clear or replace a session handle. It acknowledges only after translated
output has entered the bridge's bounded outbox, and only while the bridge is
open. An intentional callback close may make that ACK return `{:error, :closed}`;
already admitted output remains available. Other ACK failures close explicitly.
Monitor unrelated subprocess actor `:DOWN` messages in the adapter callback.

The optional `shutdown/1` callback may return legacy plain state, `{:ok, state}`,
or `{:error, reason, state}`. Use the error form when child cleanup could not be
confirmed. `AdapterBridge.close/1` now returns `:ok | {:error, reason}` instead
of silently claiming cleanup succeeded. A protocol input or translation error
is distinct from a cleanup failure; Pi records those separately. Pi refuses to
replace an unsuccessfully cleaned child or delete that session's storage.

## Delivery and compatibility limits

Bridge output defaults remain 1,024 messages / 4 MiB, and one-shot task
concurrency defaults to eight. Finite bridge receive deadlines begin at the
caller. Zero polls use a short scheduling lease and only consume output buffered
before the poll. Calls whose timeout expires retain the existing GenServer call
timeout behavior; they cannot later consume a buffered response.

Pi retains startup banners for session metadata up to 64 lines / 64 KiB by
default (`:max_prelude_lines`, `:max_prelude_bytes`). Explicit overflow fails
pending requests. Its unmanaged callback path accepts legacy raw input messages
through the same bounded framing reducer; it does not own that input transport.
Existing Pi golden transcripts, native request IDs, `_meta.ex_mcp` wire fields
and `~/.ex_mcp/pi/session-map.json` remain unchanged.

Queued and unacknowledged RPC frames share count/byte caps. These are managed
delivery bounds, not a hard bound on asynchronous Port driver inboxes or on
application data retained after ACK. Applications must bound concurrent writers
and downstream queues. Windows process-tree qualification, broader pressure
qualification, global stdio logger lifecycle and full runtime convergence remain
release gates. The native ACP child stdio transport is the next wrapper to adopt
this API.
