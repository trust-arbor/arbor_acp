# ArborACP adapters usage rules

The optional `arbor_acp_adapters` package translates vendor CLI protocols into
ACP. Public adapters use `Arbor.ACP.Adapters.*`; controller and session APIs
remain in `arbor_acp` (`Arbor.ACP.*`). These rules describe the independent 1.x
adapter API. Guide paths below are relative to the installed `arbor_acp_adapters`
dependency directory, usually `deps/arbor_acp_adapters`. Read `README.md` and
`docs/ADAPTER_GUIDE.md` for installation, candidate availability and vendor-specific
options.

## Select and launch the adapter explicitly

- Supported modules are `Arbor.ACP.Adapters.ClaudeSDK`,
  `Arbor.ACP.Adapters.Codex`, `Arbor.ACP.Adapters.Pi` and
  `Arbor.ACP.Adapters.ZCode`. Vendor executables and authentication are separate
  prerequisites; installing this Hex package does not install or authenticate
  those CLIs.
- Use `Arbor.ACP.Client.start_link/1` with `transport_mod: Arbor.ACP.AdapterTransport`,
  `adapter: chosen_module` and `adapter_opts: [...]`. Put vendor options such as
  executable path, cwd and environment in `adapter_opts`, not top-level options.
- Use `Arbor.ACP.Client` for session operations, prompts and cleanup. Core
  tagged results, caller deadlines, queued cancellation and bounded stop
  semantics still apply. Use `Arbor.ACP.Client.stop/3` to close and terminate;
  retain cleanup errors. Disconnect only closes the transport.
- Declare the core and RPC directly if your own code calls their APIs. Native
  source installation on macOS/Linux requires a C17 compiler through ArborRPC;
  vendor CLI availability is an additional prerequisite.

## Use returned capabilities and catalogs

- Vendor model, mode and configuration catalogs differ and can change during
  session setup. Read session responses and updates instead of guessing IDs or
  assuming every adapter supports the same operations.
- Check advertised authentication methods and optional session capabilities.
  Session creation alone does not prove vendor authentication. MCP descriptors
  describe separately provided servers; they do not install or launch them in
  the controller automatically.
- The default core client handler denies tool permission and file requests and
  declines elicitation. Implement host callbacks and matching capabilities when
  the application supports them. Full-access vendor modes are a separate host
  policy decision, not a substitute for that handler contract.

## Configure environment and workspace policy

- The default child environment is isolated. Adapter defaults, adapter `env/1`
  and explicit `adapter_opts[:env]` are applied in order; caller values win and
  `false` unsets a variable. Defaults clear inherited provider keys and nested
  session markers. Parent-shell credentials are not guaranteed to reach a child;
  HOME-based vendor login state may still be available.
- Supply needed credentials/configuration explicitly and avoid logging them.
  `environment_policy: :inherit` opts into parent inheritance but does not undo
  adapter defaults that deliberately unset variables.
- Use an absolute `adapter_opts[:cwd]`. For Codex and ZCode, workspace roots
  default to cwd; checks resolve symlinks. Supply the documented authorization
  callbacks when accepting additional workspaces or caller-provided MCP servers.
- `trusted_mcp_servers` contains exact descriptor maps. A server name alone does
  not authorize an arbitrary URL, command or environment. Codex trusted-project
  registration additionally requires `trust_authorized_workspaces: true`.
- Retain legacy `_meta.ex_mcp` wire extensions and Pi session-storage identifiers.
  Namespace changes do not authorize changing persisted vendor data.

## Extend through supported behaviours and test the right boundary

- Custom adapters implement `Arbor.ACP.Adapter` and use the core bridge,
  `Arbor.ACP.AdapterEvents` and public `Arbor.ACP.AdapterSupport` helpers.
  Do not depend on `Internal` modules, private subprocess actors, or the built-in
  adapters' session-store implementation details.
- Follow the documented optional environment, subprocess-receipt and shutdown
  callback contracts. ACK frame credit only through the bounded admission path;
  preserve known cleanup failure when replacing or deleting sessions.
- Fixture tests verify captured translations. They do not certify a live CLI,
  vendor account or network configuration. Use explicit live integration tests
  for those dependencies and retain the tested CLI versions.

See the adapter guide for per-vendor executable selection, authentication,
MCP/workspace configuration, session persistence and troubleshooting.

Core Client response semantics apply to adapted connections: `Client.prompt/4`
preserves the adapter's peer result. Use `Client.prompt_text/4` for explicit
streamed text collection and check `truncated?` before treating it as complete.
See the installed `arbor_acp/docs/ACP_GUIDE.md` for RC migration guidance.
