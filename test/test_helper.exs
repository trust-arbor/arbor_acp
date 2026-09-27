log_level =
  case System.get_env("LOG_LEVEL") do
    nil -> :info
    level -> String.to_existing_atom(level)
  end

Logger.configure(level: log_level)

{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Application.ensure_all_started(:ssl)

ExUnit.configure(
  exclude: [
    integration: true,
    external: true,
    slow: true,
    interop: true,
    wip: true,
    skip: true
  ]
)

ExUnit.start(capture_log: true)
