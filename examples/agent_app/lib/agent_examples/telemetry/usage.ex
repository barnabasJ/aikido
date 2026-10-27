defmodule AgentExamples.Telemetry.Usage do
  @moduledoc "Reads reported token counts and estimated cost without inventing missing values."

  def reported(nil, _key), do: nil

  def reported(usage, :total_cost) do
    value = usage[:total_cost] || usage[:cost]
    if is_number(value), do: value
  end

  def reported(usage, key) do
    tokens = usage[:tokens] || usage
    aliases = %{input_tokens: :input, output_tokens: :output, reasoning_tokens: :reasoning}
    value = tokens[key] || tokens[aliases[key]]
    if is_number(value), do: value
  end

  def description(:total_cost),
    do:
      "Estimated USD cost when ReqLLM has model pricing. Unavailable means pricing was not reported, not zero cost; coding-plan models may be unpriced."

  def description(key), do: "Reported #{key} from completed provider requests."
end
