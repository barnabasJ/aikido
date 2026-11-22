defmodule Aikido.Team.Errors.DeadlineExceeded do
  @moduledoc """
  A known Team deadline, with its scheduled limit and operation/task correlation.

  This error records the boundary that expired, not whether a process died or
  cancellation finished. Legacy timeout signals without a retained limit leave
  `timeout_ms` unset instead of inferring it from current configuration.
  """
  use Splode.Error,
    class: :invalid,
    fields: [:stage, :timeout_ms, :operation_id, :task_id, :member, :attempt]

  @doc "Describe the tracked lifecycle step when its operation deadline fires."
  def for_operation(operation, timeout_ms) do
    {stage, member} =
      case operation.awaiting do
        {:start, member} -> {:member_activation, member}
        {:stop, member} -> {:member_stop, member}
        {:inherit, member} -> {:member_inheritance, member}
        _ -> {:topology_operation, nil}
      end

    exception(stage: stage, timeout_ms: timeout_ms, operation_id: operation.id, member: member)
  end

  @doc "Attach a pending assignment's correlation to the same deadline cause."
  def for_pending_task(%__MODULE__{} = error, id, member) do
    error
    |> details()
    |> Map.merge(%{task_id: id, member: member})
    |> Map.to_list()
    |> exception()
  end

  def for_pending_task(reason, _id, _member), do: reason

  @doc "The public facts shared by structured errors and tool rendering."
  def details(error) do
    error
    |> Map.take([:stage, :timeout_ms, :operation_id, :task_id, :member, :attempt])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  def message(error) do
    limit = if error.timeout_ms, do: "after #{error.timeout_ms}ms", else: "(limit not retained)"

    correlation =
      error
      |> details()
      |> Map.drop([:stage, :timeout_ms])
      |> Enum.sort()
      |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

    "Team deadline expired #{limit} at stage #{error.stage}. #{correlation}. " <>
      "Inspect the correlated operation, task and member status; this does not establish a process exit or completed cancellation."
  end
end

defimpl AshAi.ToToolError, for: Aikido.Team.Errors.DeadlineExceeded do
  def to_tool_error(error), do: Exception.message(error)
end

defimpl AshLua.Error, for: Aikido.Team.Errors.DeadlineExceeded do
  def to_error(error) do
    %{
      code: "team_deadline_exceeded",
      message: Exception.message(error),
      short_message: "Team deadline exceeded",
      fields: [],
      vars: Aikido.Team.Errors.DeadlineExceeded.details(error)
    }
  end
end
