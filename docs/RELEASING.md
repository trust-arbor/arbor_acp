# Releasing ArborACP and adapters

ArborACP and its optional adapter bundle are published as `1.0.0-rc.1`.
They are independent Hex packages in one repository, not umbrella applications.
The original `2.0.0-rc.1` candidates are retired with tags and archives preserved.
Stable promotion remains gated on the final package graph and continuous soak.

## Package ownership

| Package | Project | Owning tag |
| --- | --- | --- |
| ArborACP | `packages/arbor_acp` | `arbor_acp-v<version>` |
| ArborACP adapters | `packages/arbor_acp_adapters` | `arbor_acp_adapters-v<version>` |

Update each literal version, compatible dependency requirements, changelog and
source/doc links independently. Both tags can point at one workspace commit.
Publish RPC before dependents, and core ACP before adapters. Preserve published
versions, tags and source archives.

## Qualification

- Run each package's supported/latest BEAM CI, strict compilation, formatting,
  complete relevant tests, documentation and source boundary checks.
- Run pinned official ACP SDK interoperability and unchanged vendor goldens.
  Credential-free CLI lifecycle checks do not qualify authenticated model turns.
- Exercise native/adapter startup, streaming, cancellation, limits, timeout and
  cleanup with the actual selected vendor versions and downstream applications.
- Build archives with source overrides unset. Check no vendor implementation or
  MCP runtime leaks into core, and no host paths, generated native binaries or
  test fixtures ship inadvertently.
- Install normal Hex dependencies and verify the selected versions/source bytes;
  run combined-package and assembled-release probes including typed native
  cleanup, effective child PATH and host-owned stdio logging.
- Qualify supported platforms, pressure and lifecycle boundaries on the final
  graph. Keep documented finite limits and explicit cleanup uncertainty.
- Complete the accepted continuous 48-hour final-candidate soak and performance
  decision. The earlier persistent-peer-cap harness stop was an incomplete run.

See the coordinated [release checklist](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/RELEASING.md)
and [RC testing notes](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/V2_RELEASE_CANDIDATE.md).
The [contributor guide](../CONTRIBUTING.md) provides commands. Historical short
checks or earlier source selections do not qualify a changed final artifact.

## Publication

Review exact source/archive/tag identities first. Publish from the owning project,
using a user terminal for any Hex 2FA prompt. Verify the public registry/archive,
versioned HexDocs, normal installation and GitHub tag/release independently.
Inspect retained receipts and public state before continuing any failed attempt.
