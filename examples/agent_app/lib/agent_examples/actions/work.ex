defmodule AgentExamples.Actions.Work do
  use Aikido.Action

  action do
    name "uppercase_work"

    schema do
      attribute :text, :string, allow_nil?: false
    end
  end

  @impl true
  def run(_signal, %{status: :working}, _opts, _context), do: {:error, :busy}

  def run(signal, state, _opts, _context) do
    directive =
      Aikido.Directives.async_task({__MODULE__, :uppercase, [signal.data.text]},
        success_type: "worker.completed",
        error_type: "worker.failed"
      )

    {:ok, %{state | status: :working, result: nil, error: nil}, [directive]}
  end

  # Replace this one unit of work with a blocking API/tool call in a real app.
  def uppercase(text), do: {:ok, String.upcase(text)}
end

defmodule AgentExamples.Actions.WorkResult do
  use Aikido.Action

  action do
    name "work_result"

    schema do
    end
  end

  @impl true
  def run(%{type: "worker.completed", data: %{result: result}}, state, _opts, _context) do
    {:ok, %{state | status: :completed, result: result}, []}
  end

  def run(%{type: "worker.failed", data: %{reason: reason}}, state, _opts, _context) do
    {:ok, %{state | status: :failed, error: reason}, []}
  end
end
