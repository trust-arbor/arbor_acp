defmodule Arbor.ACP.Adapters.Pi.BridgeModelPropertyTest do
  # Random interleavings of ACP requests and fake Pi events run through
  # Arbor.ACP.AdapterBridge; see Arbor.ACP.Test.PiBridgeModel for the
  # commands, the fake Pi and the invariants checked after every step.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbor.ACP.Test.PiBridgeModel, as: Model

  # PI_MODEL_RUNS=1000 explores further; PI_MODEL_TRACE=1 prints each run.
  @runs String.to_integer(System.get_env("PI_MODEL_RUNS", "40"))
  @moduletag timeout: max(60_000, @runs * 2_000)

  for mode <- [:managed, :unmanaged] do
    @mode mode
    property "#{mode} Pi answers every request once and never crosses sessions" do
      check all(commands <- Model.commands(), max_runs: @runs) do
        Model.run(@mode, commands)
      end
    end
  end

  # Shrunk failures the property found, and the review defects it reaches,
  # replayed exactly.
  @regressions [
    {[:managed, :unmanaged], "a setup during a running prompt crashed the bridge",
     [:open, {:prompt, :text}, {:reply, 0, :ok}, :new]},
    {[:unmanaged], "a setup waiting behind another was answered at once with an invented session",
     [:new, :new]},
    {[:unmanaged], "a model switch in flight published for the session the client closed",
     [:open, {:set_model, "fake/m1"}, {:close, :current}]},
    {[:unmanaged], "a prompt whose write failed was answered again by the next setup",
     [:open, :break, {:prompt, :text}, :new]},
    {[:managed],
     "a setup answered as Pi is replaced is checked against the Pi it ran on (harness)",
     [
       :open,
       :new,
       :new,
       {:reply, 5, :ok},
       {:close, :current},
       {:prompt, :text},
       {:reply, 6, :ok},
       :agent_settled,
       :new
     ]},
    {[:unmanaged], "the turn a refused setup aborted answered the next prompt",
     [
       :open,
       {:prompt, :text},
       {:reply, 0, :ok},
       :new,
       {:reply, 0, :cancelled},
       {:prompt, :text},
       :agent_end,
       :agent_settled
     ]},
    {[:managed], "the turn a cancelled waiting setup aborted answered the next prompt",
     [
       :open,
       {:prompt, :text},
       {:reply, 0, :ok},
       {:set_model, "fake/m2"},
       :new,
       {:cancel_request, 0},
       {:prompt, :text},
       :agent_end,
       :agent_settled
     ]},
    {[:unmanaged], "a close whose abort write failed dropped the cancelled prompt's answer",
     [:open, {:prompt, :text}, {:reply, 0, :ok}, :break, {:close, :current}]},
    {[:managed], "a prompt command whose write failed stayed pending",
     [:open, :break, {:prompt, :slash_session}, {:close, :current}]},
    {[:managed], "a slash prompt forwarded to Pi whose write failed stayed pending",
     [:open, :break, {:prompt, :slash_forward}, {:close, :current}]},
    {[:managed, :unmanaged], "a prompt Pi refused stranded the queued prompt",
     [:open, {:prompt, :text}, {:prompt, :text}, {:reply, 0, :fail}]}
  ]

  describe "regressions" do
    for {modes, name, commands} <- @regressions, mode <- modes do
      @mode mode
      @commands commands
      test "#{mode}: #{name}" do
        Model.run(@mode, @commands)
      end
    end
  end
end
