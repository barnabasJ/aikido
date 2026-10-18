defmodule AgentExamples.Worker do
  @moduledoc "Action -> AsyncTask -> result signal -> action; no blocking agent calls."
  use Ash.Resource, domain: AgentExamples.Agents, extensions: [Aikido.Ash.Agent]

  agent do
    name "example_worker"

    schema do
      attribute :status, :atom,
        allow_nil?: false,
        default: :idle,
        constraints: [one_of: [:idle, :working, :completed, :failed]],
        public?: true

      attribute :result, :string, public?: true
      attribute :error, :term, public?: true
    end

    signal :run, "worker.run", :work
    signal :completed, "worker.completed", :completed
    signal :failed, "worker.failed", :failed
  end

  actions do
    action :work, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        state = input.arguments.state

        if state.status == :working do
          {:error, "Worker is already busy"}
        else
          directive =
            Aikido.Directives.async_task({__MODULE__, :uppercase, [input.arguments.text]},
              success_type: "worker.completed",
              error_type: "worker.failed"
            )

          Aikido.ActionResult.new(
            state: %{state | status: :working, result: nil, error: nil},
            directives: [directive]
          )
        end
      end
    end

    action :completed, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :result, :string, allow_nil?: false

      run fn input, _context ->
        Aikido.ActionResult.new(
          state: %{input.arguments.state | status: :completed, result: input.arguments.result}
        )
      end
    end

    action :failed, Aikido.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :reason, :term, allow_nil?: false

      run fn input, _context ->
        Aikido.ActionResult.new(
          state: %{input.arguments.state | status: :failed, error: input.arguments.reason}
        )
      end
    end
  end

  def uppercase(text), do: {:ok, String.upcase(text)}
end
