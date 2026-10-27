defmodule AikidoTest.CpuWork do
  @moduledoc "Deterministic CPU work for mailbox and timeout scenarios; performs no I/O."

  def sum_steps(units), do: sum(max(units, 1) * 100_000, 0)
  defp sum(0, total), do: total
  defp sum(left, total), do: sum(left - 1, total + left)
end
