# Extraction verification

Source snapshot: `1808c56bd4fc7b000043c2775f61ecced6ed059f` from current main ExMCP. The local sibling extraction's initial Git history is preserved; its stale source copies were replaced. Original sibling and dirty cutover spike were untouched.

Each project is independently publishable as version `2.0.0-dev`. `arbor_acp` has no vendor runtime modules; `arbor_acp_adapters` is optional. Pure JSON-RPC, byte framing, environment isolation, stdio byte handling, log summaries, and line buffering live only in `arbor_rpc`. Core adapter support owns name/value validation, workspace authorization, and the temporary subprocess wrapper. Vendor session and credential policy belongs to the bundle via the optional generic `Adapter.environment_defaults/1` callback, layered before `env/1` and caller overrides.

## Completed checks

Toolchain: Elixir 1.19.5 / OTP 28.4.1, using a task-private Hex 2.5.1 archive compiled for that toolchain. External dependencies used the reviewed source cache through `ARBOR_V2_DEPS`; workspace dependencies used `ARBOR_V2_LOCAL=1`. The final verification tools are private to this task; a temporary mise-directed archive installation was removed.

- RPC: 34 tests, zero failures.
- ACP core by itself: 323 tests, zero failures, seven explicitly excluded ecosystem/SDK tests.
- ACP core plus adapter bundle: 1,436 tests, zero failures, four external CLI tests excluded.
- Pinned official ACP SDK 1.4.0 interoperability: six tests, zero failures. SDK peer dependency zod 4.4.3 is projected from the reviewed main lockfile. Test setup requires cached/preinstalled dependencies and does not run npm automatically.
- Native echo agent/controller example completes locally with the expected streamed text and `end_turn` result.
- All three projects compile in production mode with warnings as errors, and formatter checks pass.
- Fresh generator extraction suites pass (29 RPC primitive tests, 321 core tests, 1,434 adapter tests); independently implemented Framing and extraction regression files are preserved when regenerating an existing workspace.
- Source AST boundary checks pass: RPC cannot reference protocol modules; core cannot reference vendor modules; adapters cannot reference hidden core maps, envelope, or pending-request helpers.
- Real `mix hex.build` succeeds for all three packages with workspace/cache overrides absent. Metadata contains ordinary version requirements and no local checkout paths. Nested archive contents contain only library code, package manifest, formatter, license, README, and changelog: 11 RPC files, 39 core files, 41 adapter files. No dev tasks, tests, fixtures, cached dependencies, or vendor code enters the core archive.

The new CI workflow qualifies the advertised minimum (Elixir 1.17.3 / OTP 27) and current baseline (Elixir 1.19.5 / OTP 28) per package, verifies source boundaries, builds real manifests, and runs pinned SDK interoperability. The copied scheduled workflow preserves ACP draft-schema, catalog, and ecosystem probes with corrected workspace paths. CI has been prepared locally but has not run on GitHub.

## Remaining v2 gates

- Final namespace choice and corresponding migration documentation remain pending user decision; current module names are mechanical placeholders.
- Shared subprocess ownership, process-tree cleanup, bounded delivery queues, and global stdio logger lifecycle are not yet converged. The core subprocess helper and ACP stdio wrapper temporarily retain the current main implementation.
- Full runtime/scheduler redesign and the accepted full v2 protocol/API scope remain release gates.
- Minimum toolchain qualification, documentation generation, clean Hex dependency consumer installation, live credential-free ecosystem smoke, and broader cross-runtime interop remain release checks. The local workspace path checks do not establish those outcomes.
- The public trust-arbor/arbor_acp destination was created and origin points there. Implementation has not been pushed; no package has been published or release tag created.

Legacy wire `_meta.ex_mcp`, generated native request IDs, client information defaults, and Pi's `~/.ex_mcp/pi/session-map.json` location are intentionally preserved for compatibility.
