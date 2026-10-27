defmodule AgentExamples.ResilientAssistant.ToolLoopKey do
  @moduledoc "Comparison policy for the controlled loop experiment; repeated inputs count even if outputs change."

  @doc "Ignore output only for this experiment; polling tools usually need result-aware comparisons."
  def compare_inputs(batch) do
    {:ok, Enum.map(batch, fn {name, arguments, _content} -> {name, arguments} end)}
  end
end
