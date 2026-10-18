defmodule Aikido.Slices.Thread.Actions.Append do
  @moduledoc """
  Appends one entry (or a list of entries) to the conversation thread.
  Materializes the slice via `Aikido.Slices.Thread.State.new/0` when it has not been
  initialized yet.
  """

  use Aikido.Action

  alias Aikido.Slices.Thread.State

  action do
    name "thread_append"
    description "Append one or more entries to the thread."

    schema do
      attribute :entry, Aikido.Types.Union,
        description: "Entry map (or list of entry maps) to append.",
        allow_nil?: false,
        constraints: [
          types: [[type: :map, constraints: []], [type: {:array, :map}, constraints: []]]
        ]
    end
  end

  @impl true
  def run(%Jido.Signal{data: %{entry: entry}}, slice, _opts, _ctx) do
    thread = ensure_thread(slice)
    {:ok, State.append(thread, entry), []}
  end

  defp ensure_thread(%State{} = thread) do
    thread
  end

  defp ensure_thread(_) do
    State.new()
  end
end
