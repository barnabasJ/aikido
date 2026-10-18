defmodule Aikido.Slices.Thread.Actions.Ensure do
  @moduledoc """
  Ensures the agent has a `%Aikido.Slices.Thread.State{}` mounted at the `:thread` slice.
  Materializes a fresh `Aikido.Slices.Thread.State.new/1` when the slice is empty;
  otherwise no-op.
  """

  use Aikido.Action

  alias Aikido.Slices.Thread.State

  action do
    name "thread_ensure"
    description "Initialize thread state if missing."

    schema do
      attribute :metadata, :map,
        description: "Optional metadata for newly created thread.",
        default: %{}

      attribute :id, :string, description: "Optional explicit thread id."
    end
  end

  @impl true
  def run(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %State{} = thread -> {:ok, thread, []}
      _ -> {:ok, State.new(Map.to_list(data)), []}
    end
  end
end
