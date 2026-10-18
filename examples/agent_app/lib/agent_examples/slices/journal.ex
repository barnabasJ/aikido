defmodule AgentExamples.Journal do
  @moduledoc "An embedded resource whose Ash action returns the next slice state."
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Ash.Slice]

  attributes do
    attribute :entries, {:array, :string}, public?: true, allow_nil?: false, default: []
  end

  actions do
    action :append, :map do
      argument :state, :map, allow_nil?: false

      argument :data, :map,
        allow_nil?: false,
        constraints: [fields: [text: [type: :string, allow_nil?: false]]]

      run fn input, _context ->
        state = input.arguments.state
        {:ok, %{state: %{entries: state.entries ++ [input.arguments.data.text]}}}
      end
    end
  end

  slice do
    name "example_journal"

    route "journal.append", :append
  end
end
