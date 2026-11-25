defmodule Aikido.Selector.Failure do
  @moduledoc """
  Projects selector failures to exception classes and argument-free stack frames.

  Exception values, throw/exit reasons, frame arguments and frame metadata are
  deliberately omitted. Successful selector returns and explicit error returns
  remain owned by the selector and are not processed here.
  """

  @type raised :: {:error, {:selector_raised, module(), [mfa()]}}
  @type failed :: {:error, {:selector_failed, :throw | :exit | :error, [mfa()]}}

  @doc "Retain an exception's class and stack MFAs without its payload."
  @spec raised(Exception.t(), Exception.stacktrace()) :: raised()
  def raised(exception, stacktrace),
    do: {:error, {:selector_raised, exception.__struct__, frames(stacktrace)}}

  @doc "Retain the failure kind and stack MFAs without a thrown or exited value."
  @spec failed(:throw | :exit | :error, Exception.stacktrace()) :: failed()
  def failed(kind, stacktrace), do: {:error, {:selector_failed, kind, frames(stacktrace)}}

  defp frames(stacktrace), do: Enum.flat_map(stacktrace, &frame/1)

  defp frame({module, function, arguments, _metadata}), do: frame({module, function, arguments})

  defp frame({module, function, arguments})
       when is_atom(module) and is_atom(function) and is_list(arguments),
       do: [{module, function, length(arguments)}]

  defp frame({module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0,
       do: [{module, function, arity}]

  defp frame(_frame), do: []
end
