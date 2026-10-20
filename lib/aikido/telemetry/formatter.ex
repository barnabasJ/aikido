defmodule Aikido.Telemetry.Formatter do
  @moduledoc """
  Structured log formatting utilities for the Aikido telemetry system.

  Provides functions to format durations, directives, and other
  telemetry data into human-readable, scannable log output.

  ## Examples

      iex> Aikido.Telemetry.Formatter.format_duration(1_500_000)
      "1.5ms"

  """

  @default_max_length 100

  @doc """
  Convert native time to human-readable format.

  Returns a string like "1.2ms", "342μs", or "2.1s" depending on the magnitude.

  ## Examples

      iex> Formatter.format_duration(1_000)
      "1μs"

      iex> Formatter.format_duration(1_500_000)
      "1.5ms"

      iex> Formatter.format_duration(2_500_000_000)
      "2.5s"
  """
  @spec format_duration(integer() | nil) :: String.t()
  def format_duration(nil), do: "0μs"

  def format_duration(native_time) when is_integer(native_time) do
    microseconds = System.convert_time_unit(native_time, :native, :microsecond)

    cond do
      microseconds >= 1_000_000 ->
        seconds = microseconds / 1_000_000
        "#{Float.round(seconds, 2)}s"

      microseconds >= 1_000 ->
        ms = microseconds / 1_000
        "#{Float.round(ms, 2)}ms"

      true ->
        "#{microseconds}μs"
    end
  end

  def format_duration(_), do: "??"

  @doc """
  Convert native time to milliseconds.

  Returns an integer for times >= 1ms, otherwise a float with precision.

  ## Examples

      iex> Formatter.to_ms(1_500_000)
      1.5

      iex> Formatter.to_ms(5_000_000)
      5
  """
  @spec to_ms(integer() | nil) :: number()
  def to_ms(nil), do: 0

  def to_ms(native_time) when is_integer(native_time) do
    microseconds = System.convert_time_unit(native_time, :native, :microsecond)
    ms = microseconds / 1_000

    if ms == trunc(ms) do
      trunc(ms)
    else
      Float.round(ms, 3)
    end
  end

  def to_ms(_), do: 0

  defp truncate_string(str, max_length) when byte_size(str) <= max_length, do: str

  defp truncate_string(str, max_length) do
    String.slice(str, 0, max_length - 3) <> "..."
  end

  @doc """
  Returns a map of directive_type => count from a list of directives.

  ## Examples

      iex> directives = [%{type: :emit}, %{type: :emit}, %{type: :tool}]
      iex> Formatter.summarize_directives(directives)
      %{emit: 2, tool: 1}

      iex> Formatter.summarize_directives([])
      %{}
  """
  @spec summarize_directives(list()) :: map()
  def summarize_directives(nil), do: %{}

  def summarize_directives(directives) when is_list(directives) do
    directives
    |> Enum.map(&extract_directive_type/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  def summarize_directives(_), do: %{}

  defp extract_directive_type(%{__struct__: mod}) when is_atom(mod) do
    mod |> Module.split() |> List.last()
  end

  defp extract_directive_type(%{type: type}), do: type
  defp extract_directive_type({type, _}) when is_atom(type), do: type
  defp extract_directive_type(type) when is_atom(type), do: type
  defp extract_directive_type(_), do: nil

  @doc """
  Format directive summary map for logging.

  ## Examples

      iex> Formatter.format_directive_types(%{emit: 2, tool: 1, await: 1})
      "Await=1 Emit=2 Tool=1"

      iex> Formatter.format_directive_types(%{})
      ""
  """
  @spec format_directive_types(map()) :: String.t()
  def format_directive_types(nil), do: ""
  def format_directive_types(summary) when map_size(summary) == 0, do: ""

  def format_directive_types(summary) when is_map(summary) do
    summary
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join(" ", fn {type, count} ->
      formatted_type =
        case type do
          type when is_binary(type) -> type
          type -> type |> to_string() |> String.capitalize()
        end

      "#{formatted_type}=#{count}"
    end)
  end

  def format_directive_types(_), do: ""

  @doc """
  Format signal type for logging.

  Handles atoms and strings, converting to a readable format.

  ## Examples

      iex> Formatter.format_signal_type(:user_request)
      "user_request"

      iex> Formatter.format_signal_type("api_call")
      "api_call"

      iex> Formatter.format_signal_type(nil)
      "unknown"
  """
  @spec format_signal_type(atom() | String.t() | nil) :: String.t()
  def format_signal_type(nil), do: "unknown"
  def format_signal_type(type) when is_atom(type), do: to_string(type)
  def format_signal_type(type) when is_binary(type), do: type
  def format_signal_type(_), do: "unknown"

  @doc """
  Inspect a term with a length limit.

  Safely inspects any term and truncates if necessary.

  ## Examples

      iex> Formatter.safe_inspect(%{a: 1, b: 2})
      "%{a: 1, b: 2}"

      iex> Formatter.safe_inspect(String.duplicate("x", 200), 50)
      "\\\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx..."
  """
  @spec safe_inspect(term(), pos_integer()) :: String.t()
  def safe_inspect(term, max_length \\ @default_max_length) do
    term
    |> inspect(limit: 10, printable_limit: max_length, width: max_length)
    |> truncate_string(max_length)
  rescue
    _ -> "<inspect_error>"
  end
end
