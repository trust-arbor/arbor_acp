# Arbor.ACP

ACP controller/client, native agent, and generic adapter runtime. This core package depends on `arbor_rpc` and contains no vendor adapter runtime modules. Add the optional `arbor_acp_adapters` package to use built-in Claude, Codex, Pi, or ZCode integrations.

Version `2.0.0-dev` is an unpublished implementation snapshot. The accepted namespace is `Arbor.ACP.*`.

Native agents implement `Arbor.ACP.Agent.Handler` and run with `Arbor.ACP.run_agent/1`. Controllers start with `Arbor.ACP.start_client/1`. Custom adapters implement `Arbor.ACP.Adapter` and use the generic bridge. Public `Arbor.ACP.AdapterSupport` helpers own name/value validation, workspace authorization, and adapter policy over shared RPC subprocess handles; adapter packages must not call core `Internal` modules.

`Adapter.environment_defaults/1` is an optional callback for vendor-owned environment policy. It accepts unset values (`false`) and is applied after the generic baseline, before `env/1` and explicit caller `:env`. Existing `env/1` output stays unchanged.

Managed adapters identify frame credit with the pure optional `subprocess_receipt/2` callback. The bridge ACKs after bounded output admission. `shutdown/1` supports legacy state and explicit success/error tuples; bridge close exposes known cleanup failures. See the workspace's `docs/ADAPTER_EXTENSION_API.md` for exact signatures and migration details.

See `examples/acp` for a native echo agent and controller, and `test/interop` for the pinned official SDK probes. Legacy wire metadata and storage locations are preserved. Native child stdio adoption, shared subprocess pressure/platform qualification and logging convergence, runtime/scheduler redesign, and full v2 qualification remain release gates.
