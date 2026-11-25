defmodule Aikido.AiReact.Errors.ModelTimeout do
  @moduledoc "A model attempt exhausted its progress, attempt or inherited run budget."
  use Splode.Error, fields: [:kind, :timeout], class: :api

  def message(error),
    do: "Model #{error.kind} budget expired (#{error.timeout}ms)."
end
