defmodule Arbor.ACP.Test.EnvironmentFirstUse do
  @moduledoc false
  def environment_defaults(_opts), do: %{"FIRST_USE_CREDENTIAL" => false}
  def env(_opts), do: %{"FIRST_USE_OVERRIDE" => "loaded"}
end
