defmodule Aikido.AiWorker.RequestAdmission do
  @moduledoc "Processes one inner AI request outside the worker mailbox and reports confirmed native rejection."

  @doc "Return no settlement for accepted requests or ambiguous transport failure."
  def request(pid, ask, correlation) do
    case Aikido.AgentServer.call(pid, ask, fn _runtime -> {:ok, :accepted} end) do
      {:error, %Ash.Error.Forbidden{}} -> rejected(correlation, :forbidden, ask)
      {:error, %Ash.Error.Invalid{}} -> rejected(correlation, :invalid, ask)
      {:error, %Ash.Error.Framework{}} -> rejected(correlation, :runtime, ask)
      {:error, %Ash.Error.Unknown{}} -> rejected(correlation, :runtime, ask)
      _accepted_or_ambiguous -> {:signals, []}
    end
  catch
    :exit, _reason -> {:signals, []}
  end

  defp rejected(correlation, failure, ask) do
    correlation
    |> Map.take([:task_id, :member, :attempt])
    |> Map.put(:failure, failure)
    |> Aikido.AiWorker.Signals.RequestRejected.new!()
    |> Aikido.Signal.put_ctx(Aikido.Signal.ctx(ask))
  end
end
