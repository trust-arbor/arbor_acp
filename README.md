# Arbor ACP workspace

Three independent Mix projects live here:

- `packages/arbor_acp`: ACP client, native agent, and generic adapter runtime.
- `packages/arbor_acp_adapters`: optional Claude, Codex, Pi, and ZCode adapters.
- `packages/arbor_rpc`: shared JSON-RPC, framing, environment isolation, and log primitives. Both protocol libraries use this dependency; neither depends on the other.

These are unpublished `2.0.0-rc.1` implementation snapshots. Accepted namespaces are `Arbor.ACP.*` and `Arbor.RPC.*`; package and directory names remain `arbor_acp`, `arbor_acp_adapters`, and `arbor_rpc`. Git history begins with the original local ACP extraction and the current main source snapshot is recorded in `SOURCE_SNAPSHOT`.

The planned prerelease is for downstream migration testing. Follow the
[v1 to v2 migration guide](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/guides/MIGRATING_V1_TO_V2.md)
for package selection, namespace changes and host ownership requirements.
Publication is pending; stable promotion requires completing the 48-hour gate.

To verify an unpublished workspace package, set `ARBOR_V2_LOCAL=1` for internal path dependencies. For offline verification also set `ARBOR_V2_DEPS=/path/to/reviewed/deps` to a cache containing Jason and Telemetry. Then run `mix test` inside each package. Leave these overrides unset for `mix hex.build`: archive metadata must refer to normal Hex versions. The package dependencies themselves do not contain host-specific paths.

Source installation on macOS/Darwin and Linux requires a C17 compiler for the
shared `arbor_rpc` dependency, including transitive protocol-only use. `CC`
selects a compiler executable. Source archives ship reviewed C source rather than
prebuilt helpers; assembled releases include the built target helper and need no
runtime compiler. Windows native subprocess operations are unsupported, while
framing remains separate. See the [RPC source-install policy](packages/arbor_rpc/README.md#source-build-and-remaining-gates)
for the native ownership limits and final platform/architecture qualification.

`elixir scripts/check_boundaries.exs` checks production source ownership. `VERIFICATION.md` records actual results and remaining gates. Examples and pinned SDK tooling live in the core package; vendor golden fixtures and external CLI smoke tests live in the adapter package.

ACP child stdio, persistent adapter bridges and Pi managed sessions use shared owned subprocess mechanics, with bounded native write admission and retained cleanup receipts. Host-owned stdio logging is implemented; library startup and transport connection preserve host Logger policy. `VERIFICATION.md` records revision-specific local and remote CI evidence. The RPC write handoff reloads the published payload after claiming ownership, retaining original deadlines and credit limits. MCP owns its separate handler runtime/scheduler. The final 48-hour gate has not passed: the latest rehearsal stopped at the documented 10,000-entry HandlerServer cap. Broader platform coverage and stable promotion remain pending; these packages have not been published.

The historical isolated native-backend draft was based on `b46cbfe8ced0d29519462f8a83b64e5750caaa92`. The shipped source-build policy is documented in the Arbor.RPC README alongside retained cleanup receipts and remaining qualification gates. These packages remain unpublished; source-install policy is not final-graph release approval.

## Package versions and documentation

Each project can generate its own documentation; see its README for the exact
`MIX_ENV=dev mix docs --warnings-as-errors` commands. ExDoc is dev-only.
Development/RC dependencies use explicit prerelease floors. Stable 2.0.0 uses
`~> 2.0` for internal dependencies. The three package-qualified release tags
(`arbor_rpc-v<version>`, `arbor_acp-v<version>`, `arbor_acp_adapters-v<version>`)
refer to the same coordinated monorepo commit. MCP uses `v<version>` in its own
repository. Publish RPC, ACP, MCP and then the optional adapter bundle. The
[coordinated release preparation guide](https://github.com/trust-arbor/arbor_mcp/blob/ecc4ee9944dbb657b8d0bb06c614af12939fbb3e/docs/V2_PACKAGE_RELEASE.md)
describes literal version preparation, source archives and the four-package
installation/release checks. No package publication is performed by these checks.
