defmodule Aikido.Slices.AiReact.Actions.Cancel do
  @moduledoc "Cancel the current run; late model/tool results are ignored by terminal-state guards."
  use Aikido.Action

  action do
    name "ai_cancel"

    schema do
      attribute :request_id, :string, default: nil
    end
  end

  def run(signal, slice, _opts, _context) do
    requested = Map.get(signal.data, :request_id)

    if slice.status == :running && (is_nil(requested) || requested == slice.request_id),
      do: {:ok, %{slice | status: :failed, error: :cancelled}, []},
      else: {:ok, slice, []}
  end
end
