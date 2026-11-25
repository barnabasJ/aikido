defmodule Aikido.AiReact.ModelRequestBudget do
  @moduledoc "Bounds a prepared provider call by the current attempt and inherited run deadline."
  alias Aikido.AiReact.AttemptTiming

  @doc "Capture the sooner deadline once, before attempt preparation starts."
  def deadline(timing, inherited, timeout) do
    now = AttemptTiming.system_ms(timing)
    attempt = now + timeout

    if inherited && inherited <= attempt,
      do: %{expires_at: inherited, kind: :deadline, timeout: max(inherited - now, 0)},
      else: %{expires_at: attempt, kind: :attempt, timeout: timeout}
  end

  @doc "Re-evaluate the remaining budget after preparation, before provider I/O."
  def options(options, timing, deadline) do
    options =
      options
      |> Keyword.put_new(:total_timeout, Application.get_env(:req_llm, :total_timeout, :infinity))
      |> preserve_receive_default()

    case deadline.expires_at - AttemptTiming.system_ms(timing) do
      remaining when remaining > 0 ->
        options =
          Enum.reduce([:total_timeout, :receive_timeout], options, fn key, opts ->
            Keyword.update(opts, key, remaining, &clamp(&1, remaining))
          end)

        {:ok,
         Keyword.update(
           options,
           :req_http_options,
           bounded_http_options([], remaining),
           &bounded_http_options(&1, remaining)
         )}

      _ ->
        {:error,
         Aikido.AiReact.Errors.ModelTimeout.exception(
           kind: deadline.kind,
           timeout: deadline.timeout
         )}
    end
  end

  defp bounded_http_options(options, remaining) do
    options = ReqLLM.Provider.Defaults.merge_finch_options(options)

    finch =
      Enum.reduce([:pool_timeout, :request_timeout], options[:finch], fn key, opts ->
        Keyword.update(opts, key, remaining, &clamp(&1, remaining))
      end)

    Keyword.put(options, :finch, finch)
  end

  defp preserve_receive_default(options) do
    case Application.fetch_env(:req_llm, :receive_timeout) do
      {:ok, timeout} -> Keyword.put_new(options, :receive_timeout, timeout)
      :error -> options
    end
  end

  defp clamp(:infinity, remaining), do: remaining

  defp clamp(timeout, remaining) when is_integer(timeout) and timeout > 0,
    do: min(timeout, remaining)

  defp clamp(value, _remaining), do: value
end
