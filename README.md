# Arbor ACP workspace

Three independent Mix projects live here:

- `packages/arbor_acp`: ACP client, native agent, and generic adapter runtime.
- `packages/arbor_acp_adapters`: optional Claude, Codex, Pi, and ZCode adapters.
- `packages/arbor_rpc`: shared JSON-RPC, framing, environment isolation, and log primitives. Both protocol libraries use this dependency; neither depends on the other.

These are unpublished `2.0.0-dev` implementation snapshots. Current modules use `ArborACP.*` and `ArborRPC.*` while the final ecosystem namespace is being decided. Git history begins with the original local ACP extraction and the current main source snapshot is recorded in `SOURCE_SNAPSHOT`.

To verify an unpublished workspace package, set `ARBOR_V2_LOCAL=1` for internal path dependencies. For offline verification also set `ARBOR_V2_DEPS=/path/to/reviewed/deps` to a cache containing Jason and Telemetry. Then run `mix test` inside each package. Leave these overrides unset for `mix hex.build`: archive metadata must refer to normal Hex versions. The package dependencies themselves do not contain host-specific paths.

`elixir scripts/check_boundaries.exs` checks production source ownership. `VERIFICATION.md` records actual results and remaining gates. Examples and pinned SDK tooling live in the core package; vendor golden fixtures and external CLI smoke tests live in the adapter package.

Shared subprocess lifecycle, global stdio logger management, the accepted runtime/scheduler redesign, and the full v2 protocol/API work remain release gates. These packages have not been published and CI has not run on GitHub yet.
