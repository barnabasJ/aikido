defmodule Aikido.Exec.Supervisors do
  @moduledoc """
  Resolves supervisor names based on instance configuration.

  This module provides instance isolation for Aikido action execution.
  When a `aikido:` option is provided, operations are routed to instance-scoped
  supervisors instead of the global `Aikido.Action.TaskSupervisor`.

  ## Usage

  By default (no `aikido:` option), the global supervisor is used:

      Aikido.Exec.run(MyAction, %{}, %{})
      # Uses Aikido.Action.TaskSupervisor

  With instance isolation:

      Aikido.Exec.run(MyAction, %{}, %{}, aikido: MyApp.Aikido)
      # Uses MyApp.Aikido.TaskSupervisor

  ## Instance Supervisor Naming Convention

  When `aikido: MyApp.Aikido` is provided, supervisors are resolved as:
  - TaskSupervisor: `MyApp.Aikido.TaskSupervisor`

  The instance supervisors must be started as part of your application's
  supervision tree before use.
  """

  @doc """
  Returns the TaskSupervisor name to use based on options.

  ## Options

  - `:aikido` - Optional instance name (atom). When provided, returns the
    instance-scoped TaskSupervisor. When absent, returns the global supervisor.

  ## Returns

  The supervisor name as an atom.

  ## Raises

  - `ArgumentError` if `:aikido` option is provided but the instance supervisor
    is not running. This prevents silent fallback to global supervisors.

  ## Examples

      iex> Aikido.Exec.Supervisors.task_supervisor([])
      Aikido.Action.TaskSupervisor

      iex> Aikido.Exec.Supervisors.task_supervisor(aikido: MyApp.Aikido)
      MyApp.Aikido.TaskSupervisor  # raises if not running

  """
  @spec task_supervisor(keyword()) :: atom()
  def task_supervisor(opts) when is_list(opts) do
    case Keyword.fetch(opts, :aikido) do
      :error ->
        Aikido.Action.TaskSupervisor

      {:ok, nil} ->
        Aikido.Action.TaskSupervisor

      {:ok, aikido} when is_atom(aikido) ->
        sup = Module.concat(aikido, TaskSupervisor)
        assert_supervisor_running!(sup, aikido)
        sup

      {:ok, other} ->
        raise ArgumentError,
              "Expected :aikido option to be an atom (module), got: #{inspect(other)}"
    end
  end

  def task_supervisor(opts) do
    raise ArgumentError,
          "Expected opts to be a keyword list, got: #{inspect(opts)}"
  end

  @doc """
  Returns the TaskSupervisor name without validating that it's running.

  Use this when you need to resolve the supervisor name but don't want to
  raise if it's not running (e.g., for testing or introspection).

  ## Examples

      iex> Aikido.Exec.Supervisors.task_supervisor_name([])
      Aikido.Action.TaskSupervisor

      iex> Aikido.Exec.Supervisors.task_supervisor_name(aikido: MyApp.Aikido)
      MyApp.Aikido.TaskSupervisor

  """
  @spec task_supervisor_name(keyword()) :: atom()
  def task_supervisor_name(opts) when is_list(opts) do
    case Keyword.fetch(opts, :aikido) do
      :error ->
        Aikido.Action.TaskSupervisor

      {:ok, nil} ->
        Aikido.Action.TaskSupervisor

      {:ok, aikido} when is_atom(aikido) ->
        Module.concat(aikido, TaskSupervisor)

      {:ok, other} ->
        raise ArgumentError,
              "Expected :aikido option to be an atom (module), got: #{inspect(other)}"
    end
  end

  defp assert_supervisor_running!(sup, aikido) do
    if !Process.whereis(sup) do
      raise ArgumentError,
            "Instance task supervisor #{inspect(sup)} is not running. " <>
              "Ensure the supervisor is started before using aikido: #{inspect(aikido)}. " <>
              "Add `{Task.Supervisor, name: #{inspect(sup)}}` to your supervision tree."
    end
  end
end
