defmodule Aikido.Thread.Actions.Clear do
  @moduledoc "Clears thread entries using the input signal timestamp."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    thread = input.arguments.state

    context = input.context[:aikido] || %{signal: %Aikido.Signal{type: "aikido.thread.clear"}}

    if context.signal.id && thread.last_clear_id == context.signal.id do
      Aikido.Types.ActionResult.new(changes: nil)
    else
      clear(thread, context)
    end
  end

  defp clear(thread, context) do
    {:ok, identity} =
      Ash.Type.dump_to_embedded(:term, {thread.generation, thread.rev, context.signal.id})

    generation = identity |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    updated =
      Map.merge(thread, %{
        entries: [],
        entry_receipts: [],
        generation: generation,
        last_clear_id: context.signal.id,
        next_sequence: 0,
        first_sequence: 0,
        rev: thread.rev + 1,
        updated_at: Aikido.Signal.timestamp(context.signal),
        stats: %{thread.stats | entry_count: 0}
      })

    {updated, directives} = Aikido.Thread.Followers.offer_all(updated, context, :thread)

    Aikido.Types.ActionResult.new(
      changes: Aikido.Thread.Journal.changes(thread, updated),
      directives: directives
    )
  end
end
