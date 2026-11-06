defmodule Aikido.AiReact.UserMessage do
  @moduledoc """
  Composes authored text and native ReqLLM content parts into one user message.

  Text-only input retains its string representation. Multipart input retains
  an ordered content list, including its leading authored text, through queueing
  and conversation handoff. Both representations are accepted by ReqLLM's
  native user-message constructor.
  """

  @doc "Compose one user input without changing text-only callers."
  def content(text, parts \\ [])
  def content(text, []), do: text

  def content(text, parts),
    do: [ReqLLM.Message.ContentPart.text(text) | parts]
end
