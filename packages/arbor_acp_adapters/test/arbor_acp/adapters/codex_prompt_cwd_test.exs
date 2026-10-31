defmodule Arbor.ACP.Adapters.CodexPromptCwdTest do
  @moduledoc """
  session/prompt cwd values must stay inside the session's bound workspace.
  """

  use ExUnit.Case, async: true

  alias Arbor.ACP.AdapterSupport.WorkspacePath
  alias Arbor.ACP.Adapters.Codex

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("codex_prompt_cwd_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "ws")
    outside = Path.join(root, "outside")
    inside = Path.join(workspace, "sub")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.mkdir_p!(inside)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, state} = Codex.init(workspace_roots: [workspace], cwd: workspace)
    state = start_live_thread(state, "thread-1", workspace)

    %{state: state, workspace: workspace, outside: outside, inside: inside}
  end

  test "rejects an absolute cwd outside the session root and does not start a turn",
       %{state: state} do
    pending_before = state.pending_requests

    assert {:error, reason, state_after} = prompt(state, "/etc")
    assert reason =~ ~r/not authorized|workspace|cwd/i
    refute_turn_start(pending_before, state_after)
  end

  test "rejects a ../ escape from the session root and does not start a turn",
       %{state: state, workspace: workspace, outside: outside} do
    pending_before = state.pending_requests
    escaped = Path.join(workspace, "../outside")

    assert {:error, reason, state_after} = prompt(state, escaped)
    assert reason =~ ~r/not authorized|workspace|cwd/i
    refute_turn_start(pending_before, state_after)
    assert File.dir?(outside)
  end

  test "rejects a symlink inside the root that points outside and does not start a turn",
       %{state: state, workspace: workspace, outside: outside} do
    pending_before = state.pending_requests
    link = Path.join(workspace, "link")
    File.ln_s!(outside, link)

    assert {:error, reason, state_after} = prompt(state, link)
    assert reason =~ ~r/not authorized|workspace|cwd/i
    refute_turn_start(pending_before, state_after)
  end

  test "omitted cwd still starts a turn with the session cwd", %{
    state: state,
    workspace: workspace
  } do
    msg = prompt_message(nil)

    assert {:ok, data, _state} = Codex.translate_outbound(msg, state)
    turn = decode(data)
    assert turn["method"] == "turn/start"
    assert turn["params"]["cwd"] == workspace
  end

  test "a cwd inside the session root still starts a turn", %{state: state, inside: inside} do
    assert {:ok, data, _state} = prompt(state, inside)
    turn = decode(data)
    assert turn["method"] == "turn/start"

    assert WorkspacePath.canonical(turn["params"]["cwd"]) == WorkspacePath.canonical(inside)
  end

  test "rejects a cwd that cannot be resolved and does not start a turn", %{
    state: state,
    workspace: workspace
  } do
    pending_before = state.pending_requests
    loop_a = Path.join(workspace, "loop-a")
    loop_b = Path.join(workspace, "loop-b")
    File.ln_s!(loop_b, loop_a)
    File.ln_s!(loop_a, loop_b)

    assert {:error, reason, state_after} = prompt(state, loop_a)
    assert reason =~ ~r/not authorized|workspace|cwd|resolv/i
    refute_turn_start(pending_before, state_after)
  end

  defp prompt(state, cwd), do: Codex.translate_outbound(prompt_message(cwd), state)

  defp prompt_message(cwd) do
    params =
      %{"sessionId" => "thread-1", "prompt" => [%{"type" => "text", "text" => "hi"}]}
      |> then(fn params ->
        if is_nil(cwd), do: params, else: Map.put(params, "cwd", cwd)
      end)

    %{"method" => "session/prompt", "id" => "acp-prompt", "params" => params}
  end

  defp refute_turn_start(pending_before, state_after) do
    started =
      Enum.any?(state_after.pending_requests, fn {id, entry} ->
        entry.type == :turn_start and not Map.has_key?(pending_before, id)
      end)

    refute started, "session/prompt must not send turn/start for a cwd outside the session root"
  end

  defp start_live_thread(state, thread_id, cwd) do
    msg = %{"method" => "session/new", "id" => 90, "params" => %{"cwd" => cwd}}
    assert {:ok, data, state} = Codex.translate_outbound(msg, state)

    native_id =
      data
      |> IO.iodata_to_binary()
      |> String.trim()
      |> Jason.decode!()
      |> Map.fetch!("id")

    assert {:messages, [%{"id" => 90}], state} =
             Codex.translate_inbound(
               Jason.encode!(%{
                 "id" => native_id,
                 "result" => %{"thread" => %{"id" => thread_id, "cwd" => cwd}}
               }),
               state
             )

    state
  end

  defp decode(data) do
    data
    |> IO.iodata_to_binary()
    |> String.trim()
    |> Jason.decode!()
  end
end
