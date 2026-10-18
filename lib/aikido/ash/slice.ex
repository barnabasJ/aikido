defmodule Aikido.Ash.Slice do
  @moduledoc """
  Embedded Ash resource extension for agent slices.

  Use with `data_layer: :embedded`. A routed generic Ash action receives
  `state` (the current slice map) and `data` (signal payload) as arguments and
  returns `%{state: new_state, directives: directives}`. The agent pipeline
  applies that returned state and executes the directives after the action.

  Mounting the slice automatically exposes its routed public actions on the
  agent's domain interface, using the Ash action names and payload contracts.
  Private actions and schedule-only actions remain internal.
  """
  defmodule Route do
    @moduledoc false
    defstruct [:type, :action, __spark_metadata__: nil]
  end

  defmodule Schedule do
    @moduledoc false
    defstruct [:cron, :action, data: %{}, __spark_metadata__: nil]
  end

  @route %Spark.Dsl.Entity{
    name: :route,
    target: Route,
    args: [:type, :action],
    schema: [type: [type: :string, required: true], action: [type: :atom, required: true]]
  }
  @slice %Spark.Dsl.Section{
    name: :slice,
    sections: [Aikido.Dsl.Schema.attribute_section()],
    schema: [
      name: [type: :string, required: true]
    ],
    entities: [@route]
  }
  @subscription %Spark.Dsl.Entity{
    name: :subscription,
    target: Aikido.Slice.SubscriptionEntry,
    args: [:sensor, :config],
    schema: [sensor: [type: :module, required: true], config: [type: :map, default: %{}]]
  }
  @subscriptions %Spark.Dsl.Section{name: :subscriptions, entities: [@subscription]}
  @schedule %Spark.Dsl.Entity{
    name: :schedule,
    target: Schedule,
    args: [:cron, :action],
    schema: [
      cron: [type: :string, required: true],
      action: [type: :atom, required: true],
      data: [type: :map, default: %{}]
    ]
  }
  @schedules %Spark.Dsl.Section{name: :schedules, entities: [@schedule]}
  use Spark.Dsl.Extension,
    sections: [@slice, @subscriptions, @schedules],
    transformers: [Aikido.Ash.Transformers.Slice]

  @doc false
  def run(resource, action, signal, state, context) do
    input =
      Ash.ActionInput.for_action(resource, action, %{state: state || %{}, data: signal.data},
        context: %{aikido: context}
      )

    case Ash.run_action(input) do
      {:ok, %{state: new_state} = result} when is_map(new_state) ->
        case Map.get(result, :directives, []) do
          directives when is_list(directives) -> {:ok, new_state, directives}
          _ -> {:error, "Slice action directives must be a list"}
        end

      {:ok, result} ->
        {:error,
         "Slice action must return %{state: map, directives: list}, got: #{inspect(result)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
