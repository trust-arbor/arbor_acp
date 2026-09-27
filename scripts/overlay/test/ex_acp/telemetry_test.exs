defmodule ExACP.TelemetryTest do
  use ExUnit.Case, async: true

  # Keeps ExACP.Telemetry.events/0 honest: downstream code (including ExMCP's
  # 1.x compatibility re-emitter) attaches to exactly this list, so an event
  # emitted in lib/ but missing here would silently never reach it.
  test "events/0 lists exactly the events emitted in lib/" do
    emitted =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn path ->
        ~r/:telemetry\.execute\(\s*(\[[^\]]*\])/
        |> Regex.scan(File.read!(path), capture: :all_but_first)
        |> Enum.map(fn [event] -> event |> Code.eval_string() |> elem(0) end)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert emitted == Enum.sort(ExACP.Telemetry.events())
  end
end
