#!/usr/bin/env elixir

defmodule ACPExampleController do
  def run do
    agent_script = Path.expand("echo_agent.exs", __DIR__)
    repo_root = Path.expand("../..", __DIR__)
    mix_path = System.find_executable("mix") || "mix"
    cwd = File.cwd!()

    {:ok, client} =
      Arbor.ACP.start_client(
        command: [mix_path, "run", "--no-compile", "--no-start", agent_script],
        cd: repo_root,
        env: local_workspace_env(),
        event_listener: self(),
        client_info: %{"name" => "ex-mcp-example-controller", "version" => "1.0.0"}
      )

    try do
      {:ok, %{"sessionId" => session_id}} = Arbor.ACP.Client.new_session(client, cwd)

      prompt = "Hello from Arbor.ACP's controller"
      prompt_task = Task.async(fn -> Arbor.ACP.Client.prompt(client, session_id, prompt) end)

      result =
        Stream.repeatedly(fn -> receive_next_update(prompt_task, session_id) end)
        |> Enum.reduce_while(nil, fn
          {:update, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}},
          _result ->
            IO.write(text)
            {:cont, nil}

          {:update, _update}, _result ->
            {:cont, nil}

          {:result, result}, _result ->
            {:halt, result}
        end)

      IO.puts("\n\nPrompt result: #{inspect(result)}")
    after
      Arbor.ACP.Client.disconnect(client)
    end
  end

  # Unpublished workspace packages need explicit local dependency/tool overrides
  # in the otherwise isolated child environment.
  defp local_workspace_env do
    if System.get_env("ARBOR_V2_LOCAL") == "1" do
      for key <- ~w(ARBOR_V2_LOCAL ARBOR_V2_DEPS ARBOR_RPC_PATH MIX_ARCHIVES),
          value = System.get_env(key),
          is_binary(value),
          do: {key, value}
    else
      []
    end
  end

  defp receive_next_update(task, session_id) do
    receive do
      {:acp_session_update, ^session_id, update} ->
        {:update, update}

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        {:result, result}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:result, {:error, reason}}
    after
      30_000 ->
        {:result, {:error, :timeout}}
    end
  end
end

ACPExampleController.run()
