defmodule ArborACP.TestHelpers do
  @moduledoc false
  def wait_until(condition, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1_000)
    interval = Keyword.get(opts, :interval, 10)
    do_wait_until(condition, interval, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait_until(condition, interval, deadline) do
    if condition.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise ExUnit.AssertionError, message: "wait_until timed out after condition was not met"
      end

      Process.sleep(interval)
      do_wait_until(condition, interval, deadline)
    end
  end
end
