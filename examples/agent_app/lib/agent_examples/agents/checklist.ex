defmodule AgentExamples.Checklist do
  @moduledoc "Two commands share a state contract and preserve state on a business error."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_checklist"

    schema do
      attribute :items, {:array, :string}, allow_nil?: false, default: [], public?: true

      attribute :completed, :integer,
        allow_nil?: false,
        default: 0,
        constraints: [min: 0],
        public?: true
    end

    signal :add, "checklist.add", :add
    signal :complete, "checklist.complete", :complete
  end

  actions do
    action :add, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :item, :string, allow_nil?: false

      run fn input, _context ->
        state = input.arguments.state
        Aikido.ActionResult.new(state: %{state | items: state.items ++ [input.arguments.item]})
      end
    end

    action :complete, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :item, :string, allow_nil?: false

      run fn input, _context ->
        %{state: state, item: item} = input.arguments

        if item in state.items do
          Aikido.ActionResult.new(
            state: %{
              state
              | items: List.delete(state.items, item),
                completed: state.completed + 1
            }
          )
        else
          {:error, "Unknown checklist item: #{item}"}
        end
      end
    end
  end
end
