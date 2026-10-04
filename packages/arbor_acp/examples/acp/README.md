# ACP Examples

These examples show both sides of the Agent Client Protocol:

- `echo_agent.exs` exposes a native Elixir ACP agent over stdio.
- `controller.exs` starts that agent as a subprocess, creates a session, sends a prompt, and prints streamed updates plus the final prompt result.

From `packages/arbor_acp` (set `ARBOR_V2_LOCAL=1` before the first release):

```bash
mix deps.get
mix compile
mix run examples/acp/controller.exs
```

The naming follows the official ACP SDK roles:

- `ArborACP.Client` is the controller/client side of the protocol.
- `ArborACP.Agent` is the agent/server side of the protocol.
