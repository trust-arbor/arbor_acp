# ArborACP adapter guide

The optional `arbor_acp_adapters` package translates vendor CLI protocols into
ACP. Install it alongside the core as described in the [README](../README.md),
then use `Arbor.ACP.Client` for sessions and prompts. Vendor executables and
credentials are separate prerequisites. This unpublished RC describes the
checked-in implementations; fixture coverage is not a promise that every future
CLI version or live account configuration works.

## Choose and launch an adapter

Pass the module as `adapter`, and vendor settings inside `adapter_opts`:

| Agent | Module | Child protocol | Executable option and fallback |
| --- | --- | --- | --- |
| Claude Code | `Arbor.ACP.Adapters.ClaudeSDK` | SDK stream-json control protocol | `cli_path`, then `CLAUDE_CODE_EXECUTABLE`, then `claude` |
| Codex | `Arbor.ACP.Adapters.Codex` | `app-server` JSON-RPC | `codex_path`, then `CODEX_PATH`, then `codex` |
| Pi | `Arbor.ACP.Adapters.Pi` | `--mode rpc --no-themes` | `cli_path`, `pi_command`, `PI_ACP_PI_COMMAND`, Pi settings, then `pi` |
| ZCode | `Arbor.ACP.Adapters.ZCode` | `app-server` NDJSON | `cli_path`, then `ZCODE_EXECUTABLE`, then `zcode` |

The README contains a complete Codex session including cleanup. For another
vendor, change the module and its options. For example, with an already installed
and authenticated Claude Code CLI:

```elixir
{:ok, client} = Arbor.ACP.Client.start_link(
  transport_mod: Arbor.ACP.AdapterTransport,
  adapter: Arbor.ACP.Adapters.ClaudeSDK,
  adapter_opts: [cli_path: "claude", cwd: File.cwd!()]
)
# Use Arbor.ACP.Client.new_session/3 and prompt/4, then stop/1 in an after block.
```

For temporary adapted connections, `Arbor.ACP.Client.with_connection/2,3`
accepts those same client options and closes the owned connection after its
callback. `Client.prompt/4` preserves the peer result. To collect streamed
message text, use `Client.prompt_text/4` and check the separate `text` and
`truncated?` fields; see the core ACP guide for its bounds and RC migration.

Models, modes and supported configuration controls differ by vendor and may be
loaded during session setup. Use the agent/session capabilities and returned
catalogs instead of guessing model IDs. The client defaults to denying tool
permission and file requests and declining elicitation. Implement a host handler
for interactive approvals; enabling a vendor's full-access mode is a separate
application policy choice.

## Environment and authentication

The default child environment is isolated. It retains a small RPC baseline
including PATH, HOME, temporary-directory, locale and certificate settings, then
applies generic adapter defaults, vendor `environment_defaults/1`, adapter
`env/1`, and explicit `adapter_opts[:env]`. Explicit caller values win. A value
of `false` unsets a variable.

Built-in adapter defaults clear inherited provider keys and nested Claude session
markers. Explicitly pass the credentials/configuration needed by the child;
putting a key in the parent shell alone does not guarantee it reaches the agent.
HOME remains available, so existing vendor login state may still be used.

```elixir
adapter_opts = [
  cwd: File.cwd!(),
  env: %{"OPENAI_API_KEY" => System.fetch_env!("OPENAI_API_KEY")}
]
# Use with the Codex adapter when API-key authentication is appropriate.
```

Avoid logging those values. `environment_policy: :inherit` in `adapter_opts`
opts into the parent environment before the adapter's explicit defaults and
overrides are applied; it does not undo defaults that deliberately unset keys.
Prefer explicit values for a reproducible host configuration.

`Arbor.ACP.Client.auth_methods/1` returns advertised methods. Use
`authenticate/3` with the selected method and its parameters, or complete vendor
terminal login before launch when that is the advertised flow. Browser/form/URL
authentication depends on host capabilities. Codex device-code login is advertised
only to a client with URL elicitation. Check returned errors rather than assuming
session creation authenticated the vendor.

## Workspace and MCP configuration

Set `adapter_opts[:cwd]` to an absolute project directory. For Codex and ZCode,
`workspace_roots` defaults to that working directory. Session paths and MCP
descriptors are checked as untrusted input; workspace checks resolve symlinks.
An application can supply `authorize_workspace` and `authorize_mcp_server`
callbacks. Codex's trusted-project setting additionally requires
`trust_authorized_workspaces: true`.

`trusted_mcp_servers` accepts exact server descriptor maps. A name alone does not
authorize a caller-supplied URL, command or environment. For example:

```elixir
cwd = File.cwd!()
tools = Arbor.ACP.Types.http_mcp_server("local-tools", "http://localhost:4000/mcp")
adapter_opts = [cwd: cwd, workspace_roots: [cwd], trusted_mcp_servers: [tools]]
# Use these options with Codex or ZCode, then request mcp_servers: [tools]
# in Client.new_session(client, cwd, mcp_servers: [tools]).
```

This assumes a separately running MCP server at that URL. Codex supports HTTP
and authorized stdio MCP descriptors; ZCode additionally maps SSE descriptors.
Additional workspace directories require the corresponding ACP capability;
ZCode rejects non-empty additional-directory requests.

### Claude Code launch-time MCP servers

Claude's subprocess must receive MCP configuration when it starts:

```elixir
adapter_opts = [
  cwd: File.cwd!(),
  strict_mcp_config: true,
  mcp_servers: %{
    "local-tools" => %{"type" => "http", "url" => "http://localhost:4000/mcp"}
  }
]
```

This is a map of names to Claude configuration, not an ACP `mcpServers` list.
The adapter writes it to a 0600 file in a fresh 0700 directory and removes that
file when the owning bridge exits. `mcp_config_path` instead accepts existing
configuration file paths managed by the host, relative to `cwd` or absolute.
`strict_mcp_config: true` asks Claude to use only the supplied configuration.

Session `mcp_servers` do not attach new servers to an already running Claude
process. The adapter advertises no session MCP transport and reports
`mcpCapabilities._meta.ex_mcp.claude_sdk.sessionMcpServers` as false. Configure
MCP at launch, then create the ACP session.

## Vendor behavior and limits

### Claude Code

`ClaudeSDK` handles streaming chunks, tool permissions, prompt cancellation,
session persistence/replay, prompt queues, and runtime configuration. Session
list/load/fork/delete operate on Claude's local JSONL store; session load replays
history and resume does not. The native session UUID is retained under
`_meta.ex_mcp.claude_sdk.sessionId`.

Configuration may include mode, model, effort, fast mode and agent selection as
supported by the session. Bypass permission mode requires an explicit dangerous
mode opt-in. Form questions require an elicitation-capable host and otherwise
fail closed. See `Arbor.ACP.Adapters.ClaudeSDK` for launch options and the exact
MCP configuration contract.

Claude's `read_file.max_bytes` is enforced on the text returned to Claude. When
present, it must be a non-negative integer; zero permits only empty contents.
The adapter rejects responses above that UTF-8 byte limit with a control error
instead of returning a partial file. ACP's `fs/read_text_file` has line-based
`line` and `limit` fields, so the byte cap stays in the adapter's request
correlation rather than being sent as an invented ACP option. Host file-read
callbacks must still bound their own filesystem reads, and the bridge's frame
and outbox limits apply independently. An absent cap preserves ordinary reads;
malformed or invalid UTF-8 content is refused.

### Codex

`Codex` maintains an app-server process and maps thread/session lifecycle,
streaming tools and text, history replay, model/config catalogs, MCP servers,
permissions and elicitation. Modes are `read-only`, `agent`, and
`agent-full-access`; removed legacy mode aliases are not accepted.

Session config options include mode, model, reasoning effort and fast mode when
the selected model supports it. Changes apply to subsequent turns. Dynamic tool
calls, ChatGPT token refresh and attestation generation are rejected explicitly;
secret user-input questions are not exposed as ordinary ACP forms.

### Pi

`Pi` owns a managed subprocess for each loaded or resumed session and completes
prompts at Pi's `agent_settled` boundary. The implementation requires Pi 0.80.4
or newer for that event; the credential-free CLI suite records its reviewed
version separately. Thinking levels and models come from session configuration.

Session discovery combines Pi JSONL files with the preserved
`~/.ex_mcp/pi/session-map.json`. `session_map_path`, `session_dir` and
`session_path` allow explicit storage locations. Deleting a session removes
map state by default; deleting backing JSONL files requires
`delete_session_files: true` and confinement to the configured session directory.
For an isolated Pi settings directory, pass `agent_dir` and the same path as
`PI_CODING_AGENT_DIR` in `env`.

Pi supports prompt queues, model/thought controls and mapped slash commands.
Extension select/confirm dialogs map to permission choices; input/editor requests
return cancellation. Images are supported; audio is not. Legacy Pi-specific
`_ex_mcp.pi/*` and `pi/*` extension methods are removed. Use ACP session methods
or supported slash commands. Startup banners are limited to 64 lines / 64 KiB
by default, and overflowing that budget fails pending work.

### ZCode

`ZCode` maps the Protocol v1 app-server lifecycle, text/reasoning/tool streaming,
permissions, model catalogs and mode/thought controls. Modes include plan,
build, edit, auto and yolo, with different vendor permission policies. Inspect
the catalog and choose deliberately.

The existing explicit `session/prompt` `params.model` extension accepts a
qualified model ID, an ID from that session's catalog, or a native typed
`{providerId, modelId, options?: {reasoningLevel}}` object. It maps to
`session/send.modelSelection`, as required by ZCode 0.16.9. An explicit reasoning
level is checked against the known model catalog; an omitted level uses a
supported session choice, then the model default or first advertised level.
Without catalog metadata, validation is left to ZCode. A prompt without an
override uses the native session's selected model. Queued overrides retain the
selection resolved when queued.

Legacy flat model catalogs remain supported. Older app-server releases that
require the former `runtimeModel` prompt field are not automatically detected;
explicit prompt overrides require the `modelSelection` schema. The adapter does
not retry prompts under another field name.

ZCode accepts text prompts; image and embedded-context capabilities are not
advertised. Session delete and non-empty additional directories are unsupported.
Structured user-input requests are answered as cancelled because the corresponding
response schema is not exposed through this ACP mapping. Terminal authentication
uses the advertised ZCode login method.

## Native metadata, pressure and cleanup

Legacy `_meta.ex_mcp` extension names and native request IDs are preserved in v2.
Set `native_events: :summary` alongside `adapter` to attach adapter name and a
per-connection sequence to messages derived from native events. `:raw` additionally
includes the decoded event; the default is off. Raw content counts against queue
byte limits and may contain sensitive vendor data.

The generic bridge defaults to a 1,024-message / 4 MiB outbox and eight concurrent
one-shot tasks. Managed subprocess frames use explicit credit; the bridge
acknowledges after bounded output admission. These bounds do not cover all kernel
or application buffers. A known cleanup error is returned by `Client.disconnect/1`
or bridge close. Pi does not replace an unsuccessfully cleaned child or delete its
session storage. Keep cleanup errors visible to the host.

## Extend and troubleshoot

Custom adapters depend on the core package and implement `Arbor.ACP.Adapter`.
The required callbacks are `init/1`, `command/1`, `translate_outbound/2`, and
`translate_inbound/2`. Optional callbacks provide capability catalogs, auth,
post-connect writes, environment policy, managed process messages and shutdown.
Correlate native replies with the original ACP request and emit a final prompt
result as well as stream updates. Do not copy a streaming-only adapter skeleton
that never settles its prompt.

For native setters, return `{:pending_and_write, data, state}` when success
depends on the subprocess reply. The bridge writes `data` without synthesizing
an ACP success; `translate_inbound/2` must correlate the native reply and emit
one ACP result or error. Duplicate native responses must not settle it twice.
Write failures still become ACP errors, and client timeouts or transport closure
remain terminal for the caller. Existing immediate-reply return forms are unchanged.
Implement `outbound_write_failed/3` when retaining a native correlation for this
form: remove its pending entry without reusing the native ID or emitting a
response. The bridge emits the write error, and late native replies must be ignored.

Use `Arbor.ACP.AdapterEvents` for ACP message construction and public
`Arbor.ACP.AdapterSupport` helpers for shared policy and owned subprocess handles.
For managed frame credit, `subprocess_receipt/2` must be pure: the bridge owns the
ACK after output admission. The workspace's
[adapter subprocess contract](https://github.com/trust-arbor/arbor_acp/blob/codex/shared-subprocess/docs/ADAPTER_EXTENSION_API.md)
documents result shapes, shutdown errors and v1 handle migration. Do not call
core `Internal` modules.

| Symptom | Check |
| --- | --- |
| CLI not found | Use the correct executable option from the table; resolution uses child PATH/cwd |
| CLI works in a shell but not in ACP | Check isolated environment, explicit credentials, config directory and login state |
| Workspace or MCP request rejected | Check canonical workspace roots and exact authorized server descriptors |
| Claude ignores session MCP servers | Move configuration into launch-time `adapter_opts` |
| Agent asks permission but the action never runs | Provide a permission handler; default behavior is denial |
| Model/config rejected | Refresh session catalogs and use advertised IDs/types |
| Session load differs from resume | Load replays stored history; resume skips replay where supported |
| Pi hangs at an older completion event | Check the required `agent_settled`-capable Pi version |
| Close fails | Retain the cleanup error; do not assume the owned child has been reaped |

Ordinary tests use deterministic transcripts. The
[contributor guide](https://github.com/trust-arbor/arbor_acp/blob/codex/shared-subprocess/CONTRIBUTING.md) distinguishes
official SDK interoperability, credential-free real CLI startup, and live model
calls; those provide different evidence. See the [changelog](../CHANGELOG.md) and
the [ACP core guide](https://github.com/trust-arbor/arbor_acp/blob/codex/shared-subprocess/packages/arbor_acp/docs/ACP_GUIDE.md)
for the rest of the controller/agent API.
