defmodule Aikido.NativeActionTest do
  use ExUnit.Case, async: true

  defmodule CustomDirective do
    defstruct [:value]
  end

  defimpl Aikido.AgentServer.DirectiveExec, for: CustomDirective do
    def exec(_directive, _signal, _state), do: :ok
  end

  defmodule Actions do
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

    actions do
      action :increment, Aikido.ActionResult do
        description "Increment typed state."
        argument :state, :map, allow_nil?: false
        argument :amount, :integer, allow_nil?: false, default: 1, constraints: [min: 1]

        run fn input, _context ->
          Aikido.ActionResult.new(
            state: %{count: input.arguments.state.count + input.arguments.amount}
          )
        end
      end

      action :emit, Aikido.ActionResult do
        argument :state, :map, allow_nil?: false
        argument :directive, :term, allow_nil?: false

        run fn input, _context ->
          # Deliberately return a map: the runtime must validate it too.
          {:ok, %{state: %{count: 100}, directives: [input.arguments.directive]}}
        end
      end

      action :prepared, Aikido.ActionResult do
        argument :state, :map, allow_nil?: false

        prepare fn input, _context ->
          Ash.ActionInput.before_action(input, fn input ->
            Ash.ActionInput.set_argument(input, :state, %{prepared: true})
          end)
        end

        run fn input, _context -> Aikido.ActionResult.new(state: input.arguments.state) end
      end

      action :runtime, Aikido.ActionResult do
        argument :state, :map, allow_nil?: false

        run fn input, _context ->
          runtime = input.context.aikido

          Aikido.ActionResult.new(
            state: Map.take(runtime, [:agent_id, :signal, :slice_config, :action_opts])
          )
        end
      end

      action :invalid_result, Aikido.ActionResult do
        argument :state, :map, allow_nil?: false
        run fn _input, _context -> {:ok, %{state: %{}, directives: :invalid}} end
      end
    end
  end

  defp run(action, params \\ %{}, context \\ %{state: %{count: 2}}) do
    Aikido.Exec.run({Actions, action}, params, context, timeout: 0, telemetry: :silent)
  end

  test "actions are native Ash definitions" do
    assert Spark.Dsl.is?(Actions, Ash.Resource)
    assert Ash.Resource.Info.action(Actions, :increment).type == :action
  end

  test "actions have descriptive native names" do
    assert Ash.Resource.Info.action(Actions, :increment).name == :increment
  end

  test "descriptions are native Ash metadata" do
    assert Ash.Resource.Info.action(Actions, :increment).description == "Increment typed state."
  end

  test "actions declare the shared result type" do
    assert Ash.Resource.Info.action(Actions, :increment).returns == Aikido.ActionResult
  end

  test "payload introspection excludes runtime state" do
    assert Keyword.keys(Aikido.ActionRef.schema({Actions, :increment})) == [:amount]
  end

  test "arguments retain native defaults" do
    assert Ash.Resource.Info.action(Actions, :increment).arguments
           |> Enum.find(&(&1.name == :amount))
           |> Map.fetch!(:default) == 1
  end

  test "native input casting coerces strings" do
    assert {:ok, %{count: 5}, []} = run(:increment, %{amount: "3"})
  end

  test "native defaults apply when arguments are omitted" do
    assert {:ok, %{count: 3}, []} = run(:increment)
  end

  test "native constraints reject invalid values" do
    assert {:error, %Ash.Error.Invalid{}} = run(:increment, %{amount: 0})
  end

  test "native types reject invalid input" do
    assert {:error, %Ash.Error.Invalid{}} = run(:increment, %{amount: "invalid"})
  end

  test "required state is checked by Ash" do
    assert {:error, %Ash.Error.Invalid{}} = run(:increment, %{}, %{state: nil})
  end

  test "preparations and native before-action hooks execute" do
    assert {:ok, %{prepared: true}, []} = run(:prepared)
  end

  test "results are a reusable Ash type" do
    assert Ash.Type.NewType.new_type?(Aikido.ActionResult)

    assert {:ok, %Aikido.ActionResult{state: %{count: 1}, directives: []}} =
             Aikido.ActionResult.new(state: %{count: 1})
  end

  test "known directives validate" do
    directive = Aikido.Directives.stop(:normal)

    assert {:ok, %Aikido.ActionResult{directives: [^directive]}} =
             Aikido.ActionResult.new(state: %{}, directives: [directive])
  end

  test "custom protocol implementations validate" do
    directive = %CustomDirective{value: 1}
    assert {:ok, %{count: 100}, [^directive]} = run(:emit, %{directive: directive})
  end

  test "unknown structs cannot use the Any fallback to pass validation" do
    assert {:error, _} = run(:emit, %{directive: %URI{}})
  end

  test "plain maps are rejected as directives" do
    assert {:error, _} = run(:emit, %{directive: %{effect: :unknown}})
  end

  test "atoms are rejected as directives" do
    assert {:error, _} = run(:emit, %{directive: :unknown})
  end

  test "malformed directive lists are rejected at the execution boundary" do
    assert {:error, _} = run(:invalid_result)
  end

  test "direct Ash callers can construct validated results" do
    input = Ash.ActionInput.for_action(Actions, :increment, %{state: %{count: 2}, amount: 4})
    assert {:ok, %Aikido.ActionResult{state: %{count: 6}}} = Ash.run_action(input)
  end

  test "invalid action references return structured errors" do
    assert {:error, %Aikido.Action.Error.InvalidInputError{}} =
             Aikido.Exec.run({Actions, :missing}, %{}, %{}, timeout: 0)
  end

  test "runtime context preserves signal and mount configuration" do
    signal = Jido.Signal.new!("native.runtime", %{})

    context = %{
      state: %{},
      signal: signal,
      ctx: %{agent_id: "agent", slice_config: %{label: "mount"}},
      action_opts: %{mode: :test}
    }

    assert {:ok,
            %{
              agent_id: "agent",
              signal: ^signal,
              slice_config: %{label: "mount"},
              action_opts: %{mode: :test}
            }, []} = run(:runtime, %{}, context)
  end
end
