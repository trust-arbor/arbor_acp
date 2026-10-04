# Arbor ACP workspace

Three independent Mix projects live here:

- `packages/arbor_acp`: ACP client, native agent, and generic adapter runtime.
- `packages/arbor_acp_adapters`: optional Claude, Codex, Pi, and ZCode adapters.
- `packages/arbor_rpc`: shared JSON-RPC, framing, environment isolation, and log primitives. Both protocol libraries use this dependency; neither depends on the other.

These are unpublished `2.0.0-dev` implementation snapshots. Accepted namespaces are `Arbor.ACP.*` and `Arbor.RPC.*`; package and directory names remain `arbor_acp`, `arbor_acp_adapters`, and `arbor_rpc`. Git history begins with the original local ACP extraction and the current main source snapshot is recorded in `SOURCE_SNAPSHOT`.

To verify an unpublished workspace package, set `ARBOR_V2_LOCAL=1` for internal path dependencies. For offline verification also set `ARBOR_V2_DEPS=/path/to/reviewed/deps` to a cache containing Jason and Telemetry. Then run `mix test` inside each package. Leave these overrides unset for `mix hex.build`: archive metadata must refer to normal Hex versions. The package dependencies themselves do not contain host-specific paths.

`elixir scripts/check_boundaries.exs` checks production source ownership. `VERIFICATION.md` records actual results and remaining gates. Examples and pinned SDK tooling live in the core package; vendor golden fixtures and external CLI smoke tests live in the adapter package.

ACP child stdio, persistent adapter bridges and Pi managed sessions use shared owned subprocess mechanics. Shared raw-input pressure/platform qualification, global stdio logger management, the accepted runtime/scheduler redesign, and the full v2 protocol/API work remain release gates. These packages have not been published. The initial package checkpoint passed GitHub CI; `VERIFICATION.md` records exact revision-specific local and remote evidence. Later implementation requires its own qualification.

This isolated native-backend draft is based on `b46cbfe8ced0d29519462f8a83b64e5750caaa92`. The Arbor.RPC README describes source-build installation, retained cleanup receipts and remaining platform gates. Canonical defaults and package publication are unchanged.

## Package versions and documentation

Each project can generate its own documentation; see its README for the exact
`MIX_ENV=dev mix docs --warnings-as-errors` commands. ExDoc is dev-only.
Development/RC dependencies use explicit prerelease floors. Stable 2.0.0 uses
`~> 2.0` for internal dependencies. The three package-qualified release tags
(`arbor_rpc-v<version>`, `arbor_acp-v<version>`, `arbor_acp_adapters-v<version>`)
refer to the same coordinated monorepo commit. MCP uses `v<version>` in its own
repository. The [coordinated release preparation guide](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/V2_PACKAGE_RELEASE.md)
describes literal version preparation, source archives and the four-package
installation/release checks. No package publication is performed by these checks.
