# ACP Examples

These examples show both sides of the Agent Client Protocol:

- `echo_agent.exs` exposes a native Elixir ACP agent over stdio.
- `controller.exs` starts that agent as a subprocess, creates a session, sends a prompt, and prints streamed updates plus the final prompt result.

Before the first release, clone [ArborRPC](https://github.com/trust-arbor/arbor_rpc)
separately. From `packages/arbor_acp`, set its checkout path and enable the
controller's explicit forwarding of local development settings to the echo agent:

```bash
export ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc
export ARBOR_V2_LOCAL=1
mix deps.get
mix compile
mix run examples/acp/controller.exs
```

The naming follows the official ACP SDK roles:

- `Arbor.ACP.Client` is the controller/client side of the protocol.
- `Arbor.ACP.Agent` is the agent/server side of the protocol.

The standalone echo agent configures its host-owned default logger handler to
stderr before loading the library, preserving normal levels, filters and
formatting. Agent transport connection never configures the VM logger. Configure
all additional host handlers to avoid stdout. A script using `Mix.install/2` can
still emit dependency/compiler startup output; use a compiled release for clean
stdout from process boot.
