defmodule Aikido.Inspector.History.Filter do
  @moduledoc "Case-insensitive inspector search terms; prefix a term with - to exclude matches."

  def parse(query) do
    query
    |> String.downcase()
    |> String.split()
    |> Enum.reject(&(&1 == "-"))
    |> Enum.map(fn
      "-" <> term -> {:exclude, term}
      term -> {:include, term}
    end)
  end

  def matches?(event, terms) do
    text =
      String.downcase(
        Enum.join(
          [event.agent_id, event.execution.signal.type, event[:agent_pid] || ""],
          " "
        )
      )

    Enum.all?(terms, fn
      {:include, term} -> String.contains?(text, term)
      {:exclude, term} -> !String.contains?(text, term)
    end)
  end
end
