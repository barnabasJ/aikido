defmodule Aikido.AiReact.ProviderPressure do
  @moduledoc """
  Retains a provider input-token floor only for the same provider-visible request shape.

  The fingerprint excludes executable tool callbacks and contains only their
  provider-visible descriptions. Unknown tool shapes use their full term as a
  conservative fallback. A changed shape discards the previous count, leaving
  the local conversation estimate as the handoff input.
  """

  alias Aikido.AiReact.Directives.LLMCall

  @doc "Retain or invalidate the prior provider count before a real model request."
  @spec prepare_request(state :: map(), request :: LLMCall.t()) :: map()
  def prepare_request(state, %LLMCall{} = request) do
    shape = request_shape(request)

    if Map.get(state, :last_input_shape) == shape do
      state
    else
      Map.merge(state, %{last_input_tokens: nil, last_input_shape: shape})
    end
  end

  @doc "Fingerprint model, client, generation options and prepared provider tool descriptions."
  @spec request_shape(request :: LLMCall.t()) :: String.t()
  def request_shape(%LLMCall{} = request) do
    {request.model, request.client, request.llm_opts, request.options.streaming,
     Enum.map(request.tools, &tool_description/1)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp tool_description(%ReqLLM.Tool{} = tool) do
    Map.take(tool, [:name, :description, :parameter_schema, :strict, :provider_options])
  end

  defp tool_description(other), do: other
end
