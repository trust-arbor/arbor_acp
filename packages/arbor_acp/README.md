# ArborACP

ACP controller/client, native agent, and generic adapter runtime. This core package depends on `arbor_rpc` and contains no vendor adapter runtime modules. Add the optional `arbor_acp_adapters` package to use built-in Claude, Codex, Pi, or ZCode integrations.

Version `2.0.0-dev` is an unpublished implementation snapshot. Module naming remains pending the ecosystem namespace decision.

Native agents implement `ArborACP.Agent.Handler` and run with `ArborACP.run_agent/1`. Controllers start with `ArborACP.start_client/1`. Custom adapters implement `ArborACP.Adapter` and use the generic bridge. Public `ArborACP.AdapterSupport` helpers own name/value validation, workspace authorization, and temporary subprocess support; adapter packages must not call core `Internal` modules.

`Adapter.environment_defaults/1` is an optional callback for vendor-owned environment policy. It accepts unset values (`false`) and is applied after the generic baseline, before `env/1` and explicit caller `:env`. Existing `env/1` output stays unchanged.

See `examples/acp` for a native echo agent and controller, and `test/interop` for the pinned official SDK probes. Legacy wire metadata and storage locations are preserved. Shared subprocess lifecycle and logging convergence, runtime/scheduler redesign, and full v2 qualification remain release gates.
