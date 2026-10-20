defmodule Aikido.Agent.MultiInstanceFanOutTest.SendAction do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    msg = input.arguments.message

    slice = input.arguments.state
    ctx = input.context.aikido
    slice = slice || %{}
    messages = Map.get(slice, :messages, [])
    token = get_in(ctx, [:slice_config, :token]) || "no-config"

    directives =
      if pid = ctx[:test_pid] do
        observation = %{ctx.signal | data: %{path: ctx[:slice_path], token: token, message: msg}}
        [Aikido.Directives.emit_to_pid(observation, pid)]
      else
        []
      end

    if get_in(ctx, [:slice_config, :fail?]) do
      {:error, {:planned_failure, ctx[:slice_path]}}
    else
      Aikido.Types.ActionResult.new(
        state: %{messages: messages ++ ["#{token}: #{msg}"]},
        directives: directives
      )
    end
  end
end

defmodule Aikido.Agent.MultiInstanceFanOutTest.SlackSlice do
  @moduledoc false
  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "slack_slice"

    schema do
      attribute :messages, {:array, :string},
        public?: true,
        allow_nil?: false,
        default: [],
        constraints: [items: [trim?: false, allow_empty?: true]]
    end

    route "slack.send", :send
  end

  actions do
    action :send, Aikido.Types.ActionResult do
      argument :state, :term

      argument :message, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]

      run Aikido.Agent.MultiInstanceFanOutTest.SendAction
    end
  end
end

defmodule Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "multi_slack_agent"

    slice :slack_support, Aikido.Agent.MultiInstanceFanOutTest.SlackSlice,
      options: %{token: "support-token"}

    slice :slack_sales, Aikido.Agent.MultiInstanceFanOutTest.SlackSlice,
      options: %{token: "sales-token"}
  end
end

defmodule Aikido.Agent.MultiInstanceFanOutTest.FailingMultiSlackAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "failing_multi_slack_agent"

    slice :slack_support, Aikido.Agent.MultiInstanceFanOutTest.SlackSlice,
      options: %{token: "support-token"}

    slice :slack_sales,
          Aikido.Agent.MultiInstanceFanOutTest.SlackSlice,
          options: %{token: "sales-token", fail?: true}
  end
end

defmodule Aikido.Agent.MultiInstanceFanOutTest.HostSlackAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "host_slack_agent"
    path :host

    schema do
      attribute :messages, {:array, :string},
        allow_nil?: false,
        default: [],
        constraints: [items: [trim?: false, allow_empty?: true]]
    end

    slice :slack_support, Aikido.Agent.MultiInstanceFanOutTest.SlackSlice,
      options: %{token: "support-token"}

    slice :slack_sales, Aikido.Agent.MultiInstanceFanOutTest.SlackSlice,
      options: %{token: "sales-token"}

    route "host.send", {Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}
  end
end

defmodule Aikido.Agent.MultiInstanceFanOutTest do
  @moduledoc """
  Coverage for multi-instance slice mount fan-out. When the same slice
  module is mounted at multiple paths (`slice :slack_support, SlackSlice;
  slice :slack_sales, SlackSlice`), AgentServer executes a shared action once
  per matching mount with that mount's state and `ctx.slice_config`.

  These tests cover:

    1. Compile-time acceptance of multi-instance same-slice mounts.
    2. Per-mount state writes from one signal.
    3. `ctx.slice_path` and `ctx.slice_config` visibility per fan-out
       iteration.
    4. Atomicity — first mount's success rolls back when a later mount
       errors (the turn is all-or-nothing).
    5. Edge case: action declared in BOTH a slice's routes AND
       the agent's own routes fans out across slice mounts AND
       the agent path.
  """
  use ExUnit.Case, async: true

  describe("compile-time acceptance") do
    test "the same slice module mounted at two different paths compiles cleanly" do
      refute function_exported?(Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent, :cmd, 3)

      assert function_exported?(
               Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent,
               :initialize!,
               1
             )
    end

    test "slice_paths_for_action contains both mount paths for the shared action" do
      table =
        Aikido.Dsl.Agent.Info.slice_paths_for_action(
          Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent
        )

      paths = Map.get(table, {Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}, [])
      assert :slack_support in paths
      assert :slack_sales in paths
      assert length(paths) == 2
    end

    test "mount_config_map exposes per-mount config" do
      configs =
        Aikido.Dsl.Agent.Info.mount_config_map(
          Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent
        )

      assert configs[:slack_support][:token] == "support-token"
      assert configs[:slack_sales][:token] == "sales-token"
    end
  end

  describe("runtime fan-out") do
    test "one signal updates both mount paths" do
      agent = Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent.initialize!()
      assert agent.state.slack_support.messages == []
      assert agent.state.slack_sales.messages == []
      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "hi"}})

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          signal,
          Map.merge(
            Aikido.SignalCtx.ctx(signal),
            Map.merge(%{}, %{
              agent_module: Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}, %{message: "hi"}}]
        )

      assert agent.state.slack_support.messages == ["support-token: hi"]
      assert agent.state.slack_sales.messages == ["sales-token: hi"]
    end

    test "ctx.slice_path identifies the current mount per fan-out iteration" do
      agent = Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent.initialize!()
      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "hi"}})

      {:ok, %{agent: _agent}, directives} =
        Aikido.AgentServer.apply_actions(
          signal,
          Map.merge(
            Aikido.SignalCtx.ctx(signal),
            Map.merge(%{test_pid: self()}, %{
              agent_module: Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}, %{message: "hi"}}]
        )

      assert observations(directives) == [
               {:slack_support, "support-token", "hi"},
               {:slack_sales, "sales-token", "hi"}
             ]

      refute_received {:signal, _}
      refute_received {:fan_out_call, _, _, _}

      assert {:ok, %{agent: _same_agent}, ^directives} =
               Aikido.AgentServer.apply_actions(
                 signal,
                 Map.merge(
                   Aikido.SignalCtx.ctx(signal),
                   Map.merge(%{test_pid: self()}, %{
                     agent_module: Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent,
                     agent: agent,
                     agent_id: agent.id
                   })
                 ),
                 [{{Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}, %{message: "hi"}}]
               )
    end

    test "ctx.slice_config carries the right mount's resolved config" do
      agent = Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent.initialize!()
      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "go"}})

      {:ok, %{agent: agent}, _dirs} =
        Aikido.AgentServer.apply_actions(
          signal,
          Map.merge(
            Aikido.SignalCtx.ctx(signal),
            Map.merge(%{}, %{
              agent_module: Aikido.Agent.MultiInstanceFanOutTest.MultiSlackAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}, %{message: "go"}}]
        )

      assert agent.state.slack_support.messages == ["support-token: go"]
      assert agent.state.slack_sales.messages == ["sales-token: go"]
    end
  end

  describe("atomicity — first-mount success rolls back when a later mount errors") do
    test "the input agent's state is unchanged when any mount errors" do
      agent = Aikido.Agent.MultiInstanceFanOutTest.FailingMultiSlackAgent.initialize!()
      {:ok, signal} = Jido.Signal.new(%{type: "slack.send", data: %{message: "hi"}})

      assert {:error, _, _reason} =
               Aikido.AgentServer.apply_actions(
                 signal,
                 Map.merge(
                   Aikido.SignalCtx.ctx(signal),
                   Map.merge(%{test_pid: self()}, %{
                     agent_module: Aikido.Agent.MultiInstanceFanOutTest.FailingMultiSlackAgent,
                     agent: agent,
                     agent_id: agent.id
                   })
                 ),
                 [{{Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}, %{message: "hi"}}]
               )

      fresh = Aikido.Agent.MultiInstanceFanOutTest.FailingMultiSlackAgent.initialize!()
      assert agent.state.slack_support == fresh.state.slack_support
      assert agent.state.slack_sales == fresh.state.slack_sales
      refute_received {:signal, _}
      refute_received {:fan_out_call, _, _, _}
    end
  end

  describe("edge case: action shared by slice mounts AND agent's own signal_routes") do
    test "fan-out covers slice mounts AND the agent path" do
      agent = Aikido.Agent.MultiInstanceFanOutTest.HostSlackAgent.initialize!()
      {:ok, signal} = Jido.Signal.new(%{type: "host.send", data: %{message: "broadcast"}})

      {:ok, %{agent: agent}, directives} =
        Aikido.AgentServer.apply_actions(
          signal,
          Map.merge(
            Aikido.SignalCtx.ctx(signal),
            Map.merge(%{test_pid: self()}, %{
              agent_module: Aikido.Agent.MultiInstanceFanOutTest.HostSlackAgent,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Agent.MultiInstanceFanOutTest.SlackSlice, :send}, %{message: "broadcast"}}]
        )

      assert agent.state.slack_support.messages == ["support-token: broadcast"]
      assert agent.state.slack_sales.messages == ["sales-token: broadcast"]
      assert agent.state.host.messages == ["no-config: broadcast"]

      assert observations(directives) == [
               {:slack_support, "support-token", "broadcast"},
               {:slack_sales, "sales-token", "broadcast"},
               {:host, "no-config", "broadcast"}
             ]

      refute_received {:signal, _}
    end
  end

  defp observations(directives) do
    Enum.map(directives, fn %Aikido.Directives.Emit{signal: %{data: data}} ->
      {data.path, data.token, data.message}
    end)
  end
end
