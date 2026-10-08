# ArborACP usage rules

ArborACP implements ACP controllers/clients, native agents and the generic
adapter runtime. The Hex package and OTP application are `arbor_acp`; public
modules use `Arbor.ACP.*`. These rules describe the independent 1.x API. Guide
paths below are relative to the installed `arbor_acp` dependency directory,
usually `deps/arbor_acp`. Read `README.md` and `docs/ACP_GUIDE.md` for installation,
candidate availability, callback signatures and complete examples.

## Select native ACP or an adapter

- Start a controller with `Arbor.ACP.Client.start_link/1`. Its default stdio command
  must speak ACP; an ordinary interactive CLI is not necessarily an ACP agent.
  Initialization completes before startup succeeds. ACP protocol version `1`
  is separate from MCP wire revisions and the package's version.
- Use `Arbor.ACP.Client.with_connection/2,3` for temporary connections. Its
  callback runs in the caller; finite startup/cleanup budgets and a guardian
  cover caller death. Success wraps the callback value in `{:ok, value}`;
  cleanup failures retain that value in an error. Supervise long-lived clients.
- Built-in Claude, Codex, Pi and ZCode integrations belong to the optional
  `arbor_acp_adapters` package under `Arbor.ACP.Adapters.*`. Use
  `Arbor.ACP.AdapterTransport` for adapted clients. Core consumers do not need
  the vendor bundle.
- Native agents implement `Arbor.ACP.Agent.Handler` and run through
  `Arbor.ACP.Agent.run/1` or `Arbor.ACP.Agent.start_link/1`. Custom adapters implement
  `Arbor.ACP.Adapter` and use the generic bridge and documented
  `Arbor.ACP.AdapterSupport` helpers. `Internal` modules are not extension APIs.
- Declare each package whose APIs your application calls. Shared subprocess
  ownership belongs to `arbor_rpc`; source installation on macOS/Linux requires
  a C17 compiler. See its README for platform limits.

## Use session capabilities and tagged operation results

- Create sessions with `Arbor.ACP.Client.new_session/3`, using an absolute cwd.
  `Arbor.ACP.Client.prompt/4` accepts text or content maps and returns the final
  agent result, including `stopReason`. Streamed updates arrive separately.
- `prompt/4` preserves the peer result and does not add streamed text. Use
  `Arbor.ACP.Client.prompt_text/4` to collect it explicitly: the result is
  `{:ok, %{result: peer_result, text: text, truncated?: boolean}}`. Check the
  truncation flag before treating text as complete. The byte cap is finite,
  thoughts are excluded, and collection cannot overlap a prompt in that session.
- Content builders in `Arbor.ACP.Types` emit string-keyed JSON objects with
  string discriminators. Use `Types.text_block/2` rather than atom-keyed maps.
- Read advertised capabilities, authentication methods and session model/mode
  catalogs before invoking optional operations. Close and delete have different
  meanings; loading, resuming, forking and listing depend on agent support.
- Most fallible operations return tagged success/error tuples. Pure constructors
  and accessors retain their documented bare results. Status inspection uses
  `Arbor.ACP.Client.status/2` and `Arbor.ACP.Agent.status/2`; their `status!`
  variants explicitly return a value or raise.
- Setters `Arbor.ACP.Client.set_mode/4`, `Arbor.ACP.Client.set_model/4` and
  `Arbor.ACP.Client.set_config_option/5` accept final timeout options, with a
  30-second caller default. Caller timeout returns `{:error, :timeout}`; it
  neither proves cancellation nor extends the pending request's own lifetime.
- `Arbor.ACP.Client.cancel/2` and `Arbor.ACP.Client.cancel_request/2` acknowledge
  queueing with `:ok`; they do not confirm that the remote agent acted.

## Own processes, listeners and cleanup

- Start functions return linked OTP processes. Supervise long-lived clients and
  agents and choose their restart policy deliberately.
- `Arbor.ACP.Client.disconnect/1` closes the transport and retains the client
  process. `Arbor.ACP.Client.stop/3` closes owned transport resources and waits
  for termination within one finite caller budget (default five seconds).
  Handle cleanup errors even if the process exits. `Arbor.ACP.Agent.stop/3`
  accepts a reason and finite timeout, matching Client; its options-only
  `Agent.stop/2` form remains supported. Root ACP startup functions are shorthand
  for the role modules.
- Set `event_listener: listener_pid` to receive
  `{:acp_session_update, session_id, update}`. Prompt calls block their caller;
  use an application-owned task or handler when a UI must receive updates
  concurrently. Drain the listener promptly; delivery is bounded and excess
  updates can be dropped.
- The host owns logging configuration. Keep protocol stdout free of diagnostics
  by routing host logs to stderr. Do not use VM-global log suppression as the
  ordinary stdio setup. Compiled releases avoid Mix installation/compiler output.

## Implement host capabilities explicitly

- Implement `Arbor.ACP.Client.Handler` for permission, file, terminal and
  elicitation behavior. The default handler denies permission/file requests and
  declines elicitation. Advertise only features the host actually implements.
- When capabilities are omitted, callback exports supply inference; an explicit
  capabilities map replaces that inference. `%{}` advertises none. Boolean
  configuration UI support requires its explicit capability.
- Context-aware update/permission callback variants take precedence when both
  arities exist. Follow the behaviour's exact return forms; the runtime owns
  correlation and wire replies. Selected permission option IDs must come from
  the supplied options. Validate requested paths and operations in the host.
- `Arbor.ACP.Types` constructs content and MCP descriptor maps; it does not
  read files, upload resources, or install/start MCP servers. Preserve legacy
  `_meta.ex_mcp` wire metadata; a module rename is not a wire-format rename.

Start with `examples/acp/README.md` for testing without
vendor accounts. Use documented adapter callback and bounded subprocess contracts
when extending the core rather than copying a vendor's implementation helpers.
