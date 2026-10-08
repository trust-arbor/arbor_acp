# Contributing to ArborACP

This workspace contains two independent Mix projects, not a Mix umbrella. Run
package commands inside `packages/arbor_acp` or `packages/arbor_acp_adapters`.
ArborRPC is a separate repository with its package at the checkout root.

## Prepare a source checkout

Use reviewed v2 checkouts of this workspace and
[ArborRPC](https://github.com/trust-arbor/arbor_rpc). The coordinated RC1 packages
are unpublished and the migration branches are unmerged; a default-branch clone
or prospective release tag is not a substitute for the reviewed source revision.
Use `git clone --branch codex/shared-subprocess https://github.com/trust-arbor/arbor_acp.git`
for the current workspace, and a separate RPC `main` checkout. The package CI
pins its RPC revision in `.github/workflows/ci.yml`; check out that commit when
you need to reproduce a particular CI result.

Both packages declare Elixir `~> 1.17`. Use a compatible OTP version from the
[BEAM compatibility guide](.github/BEAM_CI.md); formatting uses Elixir 1.17.3.
Source compilation on macOS/Linux requires a C17 compiler for ArborRPC. Set
`CC` to a compiler executable if needed. Windows native subprocess operations
are unsupported. Node.js/npm are needed only for the optional SDK interop suite;
vendor CLIs are needed only for explicitly selected CLI tests.

From the workspace root, configure dependencies:

```sh
export ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc
export ARBOR_V2_LOCAL=1
cd packages/arbor_acp
mix deps.get
```

`ARBOR_RPC_PATH` selects the separate RPC checkout. `ARBOR_V2_LOCAL=1` selects
the sibling core when working in the adapters package and forwards local settings
in the echo example. It does not locate RPC. Repeat `mix deps.get` from the
adapters directory before testing it.

For a reviewed offline dependency cache, optionally set
`ARBOR_V2_DEPS=/absolute/path/to/deps`. It must contain the required external
dependencies (including ExDoc and its transitive dependencies for documentation),
not only RPC. Leave the variable unset for normal Hex dependency resolution.

## Check a change

Run these commands in each affected package, with the checkout variables above:

```sh
mix format --check-formatted
mix deps.compile
mix compile --warnings-as-errors --no-deps-check
MIX_ENV=test mix deps.compile
mix test --warnings-as-errors --no-deps-check
MIX_ENV=dev mix docs --warnings-as-errors
```

The separate dependency compilation steps match CI and keep the package's
warnings gate distinct from upstream dependency warnings. ExDoc is dev-only.
Generated HTML is in each package's `doc/` directory. The core and adapter
guides are included in their own documentation and source archives.

From the workspace root, also run the source boundary check:

```sh
elixir scripts/check_boundaries.exs
```

Core changes should remain independent of vendor adapter runtime modules. Vendor
code uses public core APIs and `AdapterSupport`, not core `Internal` modules.
Shared subprocess mechanics belong in the RPC repository. Preserve existing
wire metadata and storage identifiers unless the change explicitly migrates them.

## Examples and interoperability

The [echo controller](packages/arbor_acp/examples/acp/README.md) is the first
credential-free end-to-end example. Run it from the core package after compiling:

```sh
mix run examples/acp/controller.exs
```

Default tests exclude integration/external/slow/interop groups, along with
explicit work-in-progress and skipped cases; see each package's
`test/test_helper.exs`. The adapter suite normally replays captured vendor
fixtures. It does not authenticate or call live models.

For the pinned official ACP TypeScript SDK suite, from the core package:

```sh
npm ci --ignore-scripts --prefix test/interop
mix test --only interop_acp
```

The CI interop lane uses Node 22. The checked-in npm lockfile and
`test/interop/package.json` record the SDK toolchain. SDK interoperability does
not establish compatibility with every vendor CLI.

For credential-free real CLI startup/lifecycle smoke tests, install the reviewed
CLI versions and run from the adapters package:

```sh
mix test --only interop_acp_cli
```

That suite never sends a prompt or makes an LLM request. It requires all requested
executables and fails when one is unavailable. Executable override variables are
documented in the [adapter guide](packages/arbor_acp_adapters/docs/ADAPTER_GUIDE.md).
Live authenticated prompts and provider/network behavior need separate evidence.

From the core package, inspect the ecosystem snapshot without networking:

```sh
mix acp.compat.check --offline
```

The task without `--offline` checks upstream drift over the network. It reports
changes without installing agents or rewriting the manifest. Review changes to
the manifest and captured fixtures as evidence, not automatic support promises.

## Changelogs and release checks

Update the affected package changelog for user-visible changes; the root
[changelog](CHANGELOG.md) describes workspace changes and labels historical
extraction notes. Add guides to that package's ExDoc `extras` and package `files`
when they need to ship with source archives. Keep package names (`arbor_acp`,
`arbor_acp_adapters`), module namespaces (`Arbor.ACP.*`) and display names
(ArborACP, ArborACP adapters) distinct.

Build publishable manifests without checkout overrides. From each package:

```sh
env -u ARBOR_RPC_PATH -u ARBOR_V2_DEPS ARBOR_V2_LOCAL=0 mix hex.build
```

This builds a local archive; it does not publish. Use the
[coordinated release guide](https://github.com/trust-arbor/arbor_mcp/blob/codex/v2-migration/docs/V2_PACKAGE_RELEASE.md)
for the four-package archive/consumer checks, versions, tags and publication
order. No RC1 package is published or tagged, publisher Hex authentication needs
renewal, and the final 48-hour stable-release soak has not passed. There is no
active soak. Preserve those limits when documenting validation; historical
receipts in [VERIFICATION.md](VERIFICATION.md) apply to their recorded revisions.
