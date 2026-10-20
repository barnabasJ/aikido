defmodule Aikido.Slices.AiReact.Client do
  @moduledoc """
  Model-call boundary for ReAct slices. The default client is
  `ReqLLM.Generation`; applications may supply a compatible module for local
  models, scripted tests, or provider integration. Each call returns one turn;
  the action pipeline owns conversation state and tool orchestration.
  """
  @callback generate_text(term(), [map()], keyword()) ::
              {:ok, ReqLLM.Response.t()} | {:error, term()}
  @callback stream_text(term(), list(), keyword()) ::
              {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  @optional_callbacks stream_text: 3
end
