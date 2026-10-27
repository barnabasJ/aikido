defmodule Aikido.Inspector do
  @moduledoc """
  Attaches a bounded observer to an agent and optionally its children and team members.

      {:ok, ref} = Aikido.Inspector.attach(agent.pid, projection,
        include_children?: true
      )

  The two-argument projection receives runtime state and the execution event,
  synchronously after signal processing and directive dispatch. Return `{:ok,
  value}`, `{:error, reason}` or `:skip`. Project and redact private data here;
  the inspector never needs to retain raw agent state.

  The target receives `{:aikido_inspection, ref, %{sequence: count, entries:
  entries}}` batches, oldest first. Each entry includes its sequence, agent ID,
  PID, signal type and projected result. `limit` bounds retained entries across
  the whole attachment. High-volume runs may overwrite older entries between
  batches; sequence counts still include them. No effects are replayed.

  Existing members are discovered at attachment. New descendants are observed
  directly in their signal pipeline, before they can finish and exit, without
  waiting for an asynchronous subscription handshake. Observing a descendant
  also follows its children. Membership is based on runtime ownership and team
  references, not ID prefixes. Detach explicitly with `detach/1`; attachments
  also close when the root or target exits. Historical UI records remain owned
  by the consumer.
  """
  use GenServer
  @table __MODULE__
  @registry Module.concat(__MODULE__, Attachments)
  @events Module.concat(__MODULE__, Events)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Attach a read-only projection; descendant observation is opt-in."
  def attach(root, selector, opts \\ [])

  def attach(%{pid: pid}, selector, opts), do: attach(pid, selector, opts)

  def attach(root, selector, opts) when is_pid(root) and is_function(selector, 2) do
    with {:ok, opts} <-
           Spark.Options.validate(opts,
             include_children?: [type: :boolean, default: false],
             target: [type: :pid, default: self()],
             limit: [type: :pos_integer, default: 100],
             flush_interval_ms: [type: :pos_integer, default: 100]
           ) do
      GenServer.call(__MODULE__, {:attach, root, selector, opts}, 30_000)
    end
  end

  @doc "Release an attachment and its retained observations."
  def detach(ref), do: GenServer.call(__MODULE__, {:detach, ref})

  @doc false
  def observe(runtime, event) do
    if :ets.whereis(@registry) != :undefined do
      for {ref, attachment} <- attachments(), member?(ref, attachment, runtime) do
        if attachment.include_children?, do: remember_members(ref, runtime)
        record_projection(ref, attachment, runtime, event)
        unless :ets.member(@registry, ref), do: erase(ref)
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_) do
    for table <- [@table, @registry, @events],
        do:
          :ets.new(table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:attach, root, selector, opts}, _, state) do
    ref = make_ref()

    attachment =
      Map.new(opts) |> Map.merge(%{root: root, selector: selector, counter: :atomics.new(1, [])})

    :ets.insert(@registry, {ref, attachment})
    :ets.insert(@table, {{ref, root}, true})

    case discover_existing(ref, root, attachment.include_children?, %{}) do
      :ok ->
        monitors = [Process.monitor(root), Process.monitor(attachment.target)]
        timer = Process.send_after(self(), {:flush, ref}, attachment.flush_interval_ms)

        {:reply, {:ok, ref},
         Map.put(state, ref, %{monitors: monitors, timer: timer, sequence: 0})}

      {:error, reason} ->
        erase(ref)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach, ref}, _, state), do: {:reply, :ok, release(state, ref)}

  @impl true
  def handle_info({:flush, ref}, state) do
    case state[ref] do
      nil ->
        {:noreply, state}

      session ->
        sequence = flush(ref, session.sequence)
        [{^ref, attachment}] = :ets.lookup(@registry, ref)
        timer = Process.send_after(self(), {:flush, ref}, attachment.flush_interval_ms)
        {:noreply, Map.put(state, ref, %{session | sequence: sequence, timer: timer})}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    state =
      Enum.reduce(state, state, fn {ref, session}, state ->
        if monitor in session.monitors do
          flush(ref, session.sequence)
          release(state, ref)
        else
          state
        end
      end)

    {:noreply, state}
  end

  defp attachments do
    :ets.tab2list(@registry)
  end

  defp member?(ref, attachment, runtime) do
    parent = Aikido.Ownership.parent(runtime)

    self() == attachment.root ||
      (attachment.include_children? &&
         (:ets.member(@table, {ref, self()}) ||
            (parent && :ets.member(@table, {ref, parent.pid}))))
  end

  defp remember_members(ref, runtime) do
    for pid <- [self() | member_pids(runtime)], do: :ets.insert(@table, {{ref, pid}, true})
  end

  defp member_pids(runtime) do
    children = Enum.map(Aikido.Ownership.children(runtime), fn {_, child} -> child.pid end)

    members =
      Enum.flat_map(runtime.agent.state, fn
        {_, %{__struct__: Aikido.Team.Slice, members: members}} -> Map.values(members)
        _ -> []
      end)

    Enum.filter(children ++ members, &is_pid/1) |> Enum.uniq()
  end

  @spec discover_existing(reference(), pid(), boolean(), map()) ::
          :ok | {:error, term()}
  defp discover_existing(ref, pid, descendants?, visited) do
    if Map.has_key?(visited, pid) do
      :ok
    else
      :ets.insert(@table, {{ref, pid}, true})

      case Aikido.AgentServer.state(pid, &{:ok, member_pids(&1)}) do
        {:ok, members} when descendants? ->
          visited = Map.put(visited, pid, true)
          for member <- members, do: discover_existing(ref, member, true, visited)
          :ok

        {:ok, _} ->
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  defp record_projection(ref, attachment, runtime, event) do
    result = project(attachment.selector, runtime, event)

    if result != :skip do
      sequence = :atomics.add_get(attachment.counter, 1, 1)

      entry = %{
        sequence: sequence,
        agent_id: runtime.id,
        agent_pid: self(),
        signal_type: event.signal.type,
        result: result
      }

      key = {ref, rem(sequence, attachment.limit)}
      value = {key, sequence, entry}

      unless :ets.insert_new(@events, value) do
        :ets.select_replace(@events, [
          {{key, :"$1", :"$2"}, [{:<, :"$1", sequence}], [{:const, value}]}
        ])
      end
    end
  end

  defp project(selector, runtime, event) do
    selector.(runtime, event)
  rescue
    exception -> {:error, {:selector_raised, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:selector_failed, kind, reason}}
  end

  defp flush(ref, previous) do
    [{^ref, attachment}] = :ets.lookup(@registry, ref)

    entries =
      :ets.match_object(@events, {{ref, :_}, :_, :_})
      |> Enum.map(fn {_, _, entry} -> entry end)
      |> Enum.filter(&(&1.sequence > previous))
      |> Enum.sort_by(& &1.sequence)

    sequence = :atomics.get(attachment.counter, 1)

    if entries != [],
      do:
        send(
          attachment.target,
          {:aikido_inspection, ref, %{sequence: sequence, entries: entries}}
        )

    sequence
  end

  defp release(state, ref) do
    case Map.pop(state, ref) do
      {nil, state} ->
        state

      {session, state} ->
        Process.cancel_timer(session.timer)
        for monitor <- session.monitors, do: Process.demonitor(monitor, [:flush])
        erase(ref)
        state
    end
  end

  defp erase(ref) do
    :ets.delete(@registry, ref)
    :ets.match_delete(@table, {{ref, :_}, :_})
    :ets.match_delete(@events, {{ref, :_}, :_, :_})
  end
end
