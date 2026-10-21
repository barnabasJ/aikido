defmodule Aikido.Cron.Scheduler do
  @moduledoc """
  Per-agent cron scheduling with internal timer processes.

  `Aikido.Cron.Scheduler` is intentionally lightweight and process-local:
  each registered cron job is backed by a dedicated process owned by the
  caller (typically the owning `Aikido.AgentServer`).

  The runtime stores live job processes in `AgentServer.State.cron_jobs` and
  separately stores durable schedule definitions in `AgentServer.State.cron_specs`.
  DurableServer snapshots these definitions and restores the jobs on activation.
  """

  alias Aikido.Cron.Job

  @default_timezone "Etc/UTC"

  @type cron_spec :: %{
          required(:cron_expression) => String.t(),
          required(:message) => term(),
          required(:timezone) => String.t()
        }

  @type cron_specs :: %{optional(term()) => cron_spec()}
  @type invalid_cron_spec :: {term(), term(), term()}

  @doc false
  @spec validate_and_build_cron_spec(term(), term(), term()) ::
          {:ok, cron_spec()} | {:error, term()}
  def validate_and_build_cron_spec(cron_expression, message, timezone \\ nil) do
    with :ok <- validate_cron_expression_type(cron_expression),
         {:ok, normalized_timezone} <- validate_timezone_option(timezone),
         :ok <- validate_durable_message(message) do
      {:ok,
       %{
         cron_expression: cron_expression,
         message: message,
         timezone: normalized_timezone
       }}
    end
  end

  @doc false
  @spec validate_durable_message(term()) :: :ok | {:error, term()}
  def validate_durable_message(message) do
    if durable_term?(message) do
      :ok
    else
      {:error, {:invalid_message, :non_durable_term}}
    end
  end

  @doc false
  @spec classify_cron_specs(term()) :: {cron_specs(), [invalid_cron_spec()]}
  def classify_cron_specs(specs) when is_map(specs) do
    specs
    |> Enum.reduce({%{}, []}, fn {job_id, spec}, {valid, invalid} ->
      case normalize_cron_spec(spec) do
        {:ok, normalized} ->
          {Map.put(valid, job_id, normalized), invalid}

        {:error, reason} ->
          {valid, [{job_id, spec, reason} | invalid]}
      end
    end)
    |> then(fn {valid, invalid} -> {valid, Enum.reverse(invalid)} end)
  end

  def classify_cron_specs(nil), do: {%{}, []}
  def classify_cron_specs(specs), do: {%{}, [{:manifest, specs, :invalid_manifest}]}

  @doc """
  Starts a recurring cron job.

  Returns `{:ok, pid}` where `pid` is the scheduler job process that can be
  used to cancel the job later.

  ## Options

  - `:timezone` - Timezone for the cron expression (default: "Etc/UTC")

  ## Examples

      {:ok, pid} = Aikido.Cron.Scheduler.run_every(MyModule, :work, [], "*/5 * * * *")
      {:ok, pid} = Aikido.Cron.Scheduler.run_every(fn -> IO.puts("tick") end, "* * * * *")
  """
  @spec run_every(module(), atom(), list(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def run_every(module, function, args, cron_expr, opts \\ []) do
    run_every(fn -> apply(module, function, args) end, cron_expr, opts)
  end

  @doc """
  Starts a recurring cron job with a function.

  ## Examples

      {:ok, pid} = Aikido.Cron.Scheduler.run_every(fn -> IO.puts("tick") end, "* * * * *")
  """
  @spec run_every((-> any()), term(), term()) :: {:ok, pid()} | {:error, term()}
  def run_every(fun, cron_expr, opts \\ [])

  def run_every(fun, cron_expr, opts)
      when is_function(fun, 0) and is_binary(cron_expr) and is_list(opts) do
    with {:ok, timezone} <- validate_timezone_option(Keyword.get(opts, :timezone)),
         {:ok, schedule} <- Job.prepare_schedule(cron_expr, timezone) do
      Job.start(fun, schedule, self())
    end
  end

  def run_every(fun, cron_expr, opts) when is_function(fun, 0) and is_list(opts) do
    validate_cron_expression_type(cron_expr)
  end

  def run_every(fun, _cron_expr, _opts) when is_function(fun, 0),
    do: {:error, {:invalid_scheduler_options, :invalid_type}}

  @doc """
  Cancels a running cron job.

  ## Examples

      {:ok, pid} = Aikido.Cron.Scheduler.run_every(MyModule, :work, [], "* * * * *")
      :ok = Aikido.Cron.Scheduler.cancel(pid)
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> Process.demonitor(ref, [:flush])
      end

      :ok
  end

  @spec normalize_cron_spec(term()) :: {:ok, cron_spec()} | {:error, term()}
  defp normalize_cron_spec(spec) when is_map(spec) do
    cron_expression = map_get(spec, :cron_expression)
    message = map_get(spec, :message)
    timezone = map_get(spec, :timezone)

    validate_and_build_cron_spec(cron_expression, message, timezone)
  end

  defp normalize_cron_spec(_), do: {:error, :invalid_spec}

  defp map_get(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp validate_cron_expression_type(cron_expression) when is_binary(cron_expression), do: :ok

  defp validate_cron_expression_type(_cron_expression),
    do: {:error, {:invalid_cron, :invalid_type}}

  defp validate_timezone_option(nil), do: {:ok, @default_timezone}
  defp validate_timezone_option(""), do: {:ok, @default_timezone}
  defp validate_timezone_option(timezone) when is_binary(timezone), do: {:ok, timezone}
  defp validate_timezone_option(_timezone), do: {:error, {:invalid_timezone, :invalid_type}}

  defp durable_term?(term)
       when is_pid(term) or is_reference(term) or is_port(term) or is_function(term),
       do: false

  defp durable_term?(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.all?(fn {key, value} ->
      durable_term?(key) and durable_term?(value)
    end)
  end

  defp durable_term?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.all?(&durable_term?/1)
  end

  defp durable_term?(term) when is_list(term) do
    Enum.all?(term, &durable_term?/1)
  end

  defp durable_term?(_term), do: true
end
