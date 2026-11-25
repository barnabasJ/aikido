defmodule Aikido.AiReact.StreamDelivery do
  @moduledoc "Backpressures the separate stream producer through ordinary signal processing receipts."
  alias Aikido.AiReact.{AttemptTiming, Errors.StreamDeliveryFailed}

  @doc "Whether the batch belongs to the currently running model turn and attempt."
  def active?(state, data) do
    state.status == :running && is_nil(state.handoff_pending) &&
      state.request_id == data.request_id && state.iteration + 1 == data.iteration &&
      data.attempt >= state.stream_attempt
  end

  @doc "Submit one batch without waiting; the producer owns the native OTP request ID."
  def submit(pid, signal, timing, budget) do
    if remaining(timing, budget) > 0 do
      case Aikido.AgentServer.send_request(pid, signal, &accepted(&1, signal.data)) do
        {:ok, _request} = submitted -> submitted
        {:error, _reason} -> failure(:unavailable)
      end
    else
      failure(:deadline)
    end
  end

  @doc "Poll without abandoning an outstanding request or extending its cutoff."
  def poll(request, timing, budget) do
    if remaining(timing, budget) > 0 do
      case :gen_server.wait_response(request, 0) do
        :timeout -> :pending
        response -> resolve_response(response)
      end
    else
      :gen_server.receive_response(request, 0)
      failure(:deadline)
    end
  end

  @doc "Drain the outstanding receipt at capacity or EOF, abandoning late replies on timeout."
  def await(request, timing, budget) do
    remaining = remaining(timing, budget)
    timeout = if remaining == 0, do: 0, else: AttemptTiming.control_timeout(timing, remaining)
    resolve_response(:gen_server.receive_response(request, timeout))
  end

  defp remaining(timing, budget),
    do: max(budget.monotonic_deadline - AttemptTiming.monotonic_ms(timing), 0)

  defp resolve_response({:reply, {:ok, :accepted}}), do: :ok
  defp resolve_response({:reply, {:error, :stale_batch}}), do: failure(:stale_batch)
  defp resolve_response({:reply, {:error, _reason}}), do: failure(:rejected)
  defp resolve_response({:error, _reason}), do: failure(:unavailable)
  defp resolve_response(:timeout), do: failure(:timeout)

  @doc "Select only an exact receipt from a mounted ReAct slice after the normal pipeline."
  def accepted(runtime, key) do
    accepted? =
      runtime.agent_module
      |> Aikido.Agent.Info.slice_instances()
      |> Enum.filter(&(&1.module == Aikido.AiReact.Slice))
      |> Enum.any?(fn mount ->
        state = Map.fetch!(runtime.agent.state, mount.path)

        state.stream_receipt == Map.take(key, [:request_id, :iteration, :attempt, :sequence]) &&
          active?(state, key)
      end)

    if accepted?, do: {:ok, :accepted}, else: {:error, :stale_batch}
  end

  defp failure(reason), do: {:error, StreamDeliveryFailed.exception(reason: reason)}
end
