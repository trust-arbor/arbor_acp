defmodule Arbor.ACP.Adapters.Internal.Environment do
  @moduledoc false
  alias Arbor.RPC.PortEnvironment
  @session_vars_to_clear ~w(
    CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR CLAUDECODE
    CODEX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY PI_API_KEY
  )
  def defaults(env \\ []) do
    @session_vars_to_clear
    |> Map.new(&{&1, false})
    |> Map.merge(PortEnvironment.normalize(env))
  end

  def pi(opts) do
    case Keyword.get(opts, :api_key) do
      nil -> defaults()
      api_key -> Map.put(defaults(), "PI_API_KEY", to_string(api_key))
    end
  end
end
