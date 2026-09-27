#!/usr/bin/env bash
# Regenerates ex_acp's code from ex_mcp's ACP layer.
#
# Until the cutover, ex_mcp's lib/ex_mcp/acp/ is still where ACP work lands.
# Re-run this script to refresh ex_acp from it; do not hand-edit the generated
# paths below, because the next run overwrites them. After the cutover (ex_mcp
# depends on ex_acp and lib/ex_mcp/acp/ holds only generated shims), ex_acp is
# canonical and this script is deleted.
#
# Generated (wiped and rewritten on every run):
#   lib/ex_acp.ex, lib/ex_acp/, dev/, test/ex_acp/, test/support/,
#   test/fixtures/acp/, and test/interop/acp_*
#
# Hand-maintained (never touched): mix.exs, README.md, CHANGELOG.md,
# test/test_helper.exs, config/, test/interop/package.json, and everything
# under scripts/.
# scripts/overlay/ is copied over the generated tree last, so files that need
# to differ from ex_mcp (the transport behaviour and the stdio transport, which
# in ex_mcp carry MCP-only security checks) live there.
#
# Usage: scripts/extract_from_ex_mcp.sh [path/to/ex_mcp]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(cd "${1:-$ROOT/../ex_mcp}" && pwd)"

if [[ ! -f "$SRC/lib/ex_mcp/acp.ex" ]]; then
  echo "error: $SRC does not look like an ex_mcp checkout" >&2
  exit 1
fi

cd "$ROOT"

# Internal ex_mcp helpers that the ACP layer uses. These are copied under
# ExACP.Internal so ex_acp never depends on ex_mcp (which would be circular
# once ex_mcp depends on ex_acp).
INTERNALS=(
  jsonrpc
  line_buffer
  log_summary
  maps
  name_value
  options
  port_environment
  stdio_framing
  stdio_logger_config
  workspace_path
)

# Repo-only ACP tooling (ecosystem drift check, interop agents). Like ex_mcp,
# ex_acp compiles dev/ in :dev and :test but never ships it to Hex.
DEV_TASKS=(acp.compat.check acp.everything_agent acp.interop_agent)

rm -rf lib/ex_acp.ex lib/ex_acp dev test/ex_acp test/support test/fixtures/acp test/interop/acp_*
mkdir -p lib/ex_acp/internal dev/ex_acp dev/mix/tasks test/ex_acp/internal \
  test/ex_acp/integration test/support test/fixtures test/interop

cp "$SRC/lib/ex_mcp/acp.ex" lib/ex_acp.ex
cp -R "$SRC/lib/ex_mcp/acp/." lib/ex_acp/
cp -R "$SRC/test/ex_mcp/acp/." test/ex_acp/
cp -R "$SRC/test/support/acp" test/support/acp
cp "$SRC/test/support/i18n_corpus.ex" test/support/i18n_corpus.ex
cp -R "$SRC/test/fixtures/acp" test/fixtures/acp
cp "$SRC"/test/ex_mcp/integration/acp_*.exs test/ex_acp/integration/
cp "$SRC"/test/interop/acp_* test/interop/
cp "$SRC/dev/ex_mcp/acp_compat.ex" dev/ex_acp/compat.ex
for task in "${DEV_TASKS[@]}"; do
  cp "$SRC/dev/mix/tasks/$task.ex" "dev/mix/tasks/$task.ex"
done

for name in "${INTERNALS[@]}"; do
  cp "$SRC/lib/ex_mcp/internal/$name.ex" "lib/ex_acp/internal/$name.ex"
  if [[ -f "$SRC/test/ex_mcp/internal/${name}_test.exs" ]]; then
    cp "$SRC/test/ex_mcp/internal/${name}_test.exs" "test/ex_acp/internal/${name}_test.exs"
  fi
done

# Namespace rewrite. Order matters: the specific ExMCP.* prefixes go first,
# then any remaining bare `ExMCP` word (prose, error strings, and the golden
# fixtures that pin them) becomes `ExACP`. `ExMCP.MixProject` appears only as
# captured agent output inside fixtures and is left alone.
#
# Deliberately NOT rewritten, because they are wire-visible and changing them
# would break peers during 1.x: the `_meta.ex_mcp` extension namespace, the
# `ex_mcp.mcpCapabilities` meta key, `ex_mcp_*` generated ids, and the default
# `clientInfo.name` of "ex_mcp".
find lib dev test -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.term' -o -name '*.json' \) -print0 |
  xargs -0 perl -pi -e '
    s/alias ExMCP\.ACPCompat\b/alias ExACP.Compat, as: ACPCompat/g;
    s/\bExMCP\.ACPCompat\b/ExACP.Compat/g;
    s/\bExMCP\.ACP\b/ExACP/g;
    s/\bExMCP\.Internal\./ExACP.Internal./g;
    s/\bExMCP\.Transport\b/ExACP.Transport/g;
    s/\bExMCP\.Test\.(ClaudeGolden|CodexGolden|PiGolden|I18nCorpus)\b/ExACP.Test.$1/g;
    s/\bExMCP\b(?!\.MixProject)/ExACP/g;
    s/\[:ex_mcp, :acp, /[:ex_acp, /g;
    s/\[:ex_mcp, :transport, /[:ex_acp, :transport, /g;
    s/Application\.spec\(:ex_mcp, /Application.spec(:ex_acp, /g;
    s/Application\.put_env\(:ex_mcp, :stdio_mode/Application.put_env(:ex_acp, :stdio_mode/g;
    s/`:ex_mcp` `:stdio_mode`/`:ex_acp` `:stdio_mode`/g;
    s/Application\.get_env\(:ex_mcp, :codex_legacy_auth_methods, false\)/Application.get_env(:ex_acp, :codex_legacy_auth_methods, Application.get_env(:ex_mcp, :codex_legacy_auth_methods, false))/g;
  '

cp -R scripts/overlay/. .

# `mix compile --warnings-as-errors` is the completeness check: any ex_mcp
# module the rewrite did not account for becomes an undefined ExACP.* module.
mix format
echo "Extracted ACP from $SRC ($(git -C "$SRC" rev-parse --short HEAD))"
