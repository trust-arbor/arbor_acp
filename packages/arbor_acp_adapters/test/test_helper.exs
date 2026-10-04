Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:telemetry)
ExUnit.start(capture_log: true)

ExUnit.configure(
  exclude: [
    integration: true,
    external: true,
    slow: true,
    interop: true,
    interop_acp: true,
    interop_acp_cli: true,
    interop_acp_ecosystem: true,
    wip: true,
    skip: true
  ]
)
