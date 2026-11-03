defmodule Aikido.Thread.Consumer.Retries do
  @moduledoc "Pure bounded sink retry decisions and correlated timer descriptors."

  def reset(source), do: source |> cancel() |> Map.put(:retry_attempt, 0)

  def cancel(source),
    do: %{source | retry_id: nil, retry_at: nil, retry_generation: nil}

  def failed(source, data, limit, signal) do
    if data.retry_after_ms && source.retry_attempt < limit do
      %{
        source
        | status: :retrying,
          error: data.message,
          retry_attempt: source.retry_attempt + 1,
          retry_id: signal.id,
          retry_at: Aikido.Signal.timestamp(signal) + data.retry_after_ms,
          retry_generation: data.batch.generation
      }
    else
      %{cancel(source) | status: :failed, error: data.message}
    end
  end

  def current?(source, data) do
    source.status == :retrying && source.retry_id == data.retry_id &&
      source.retry_generation == data.generation && source.cursor &&
      source.cursor.generation == data.generation
  end

  def schedule(%{status: :retrying} = source, signal) do
    due = %Aikido.Signal{
      type: "aikido.thread.consumer.retry_due",
      data: %{
        source: source.source,
        path: source.path,
        channel: source.channel,
        retry_id: source.retry_id,
        generation: source.retry_generation
      }
    }

    [Aikido.Directives.schedule(max(0, source.retry_at - Aikido.Signal.timestamp(signal)), due)]
  end

  def schedule(_source, _signal), do: []
end
