defmodule AgentExamples.Playground do
  @moduledoc "In-memory browser runs, shared across the example LiveViews."
  use GenServer
  alias AgentExamples.{AI, Catalog}
  @topic "playground"

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def subscribe, do: Phoenix.PubSub.subscribe(AgentExamples.PubSub, @topic)
  def get(owner, slug), do: GenServer.call(__MODULE__, {:get, owner, slug})

  def start(owner, slug, options),
    do: GenServer.call(__MODULE__, {:start, owner, slug, options}, 15_000)

  def command(owner, slug, action, input),
    do: GenServer.call(__MODULE__, {:command, owner, slug, action, input}, 15_000)

  @doc "The example app's request callback. Only this caller waits; LiveView stays responsive."
  def request(key, request, context, timeout \\ 120_000),
    do: GenServer.call(__MODULE__, {:request, key, request, context, timeout}, :infinity)

  def stop(owner, slug), do: GenServer.call(__MODULE__, {:stop, owner, slug}, 15_000)

  @impl true
  def init(_), do: {:ok, %{runs: %{}, tasks: %{}, subscriptions: %{}, requests: %{}}}

  @impl true
  def handle_call({:get, owner, slug}, _, state), do: {:reply, state.runs[{owner, slug}], state}

  def handle_call({:start, owner, slug, options}, _, state) do
    key = {owner, slug}

    case state.runs[key] do
      %{status: status} = run when status != :stopped -> {:reply, {:ok, run}, state}
      _ -> create_run(key, Catalog.find(slug), options, state)
    end
  end

  def handle_call({:command, owner, slug, :ask, %{query: query}}, _, state) do
    key = {owner, slug}

    case state.runs[key] do
      %{status: status} = run when status in [:ready, :completed, :failed] ->
        if String.trim(query) == "" do
          {:reply, {:error, "Enter a prompt first."}, state}
        else
          task = start_prompt_task(run.record, query, owner, slug)

          run = %{
            run
            | status: :running,
              error: nil,
              messages: run.messages ++ [%{role: :user, text: query}]
          }

          state =
            %{state | tasks: Map.put(state.tasks, task.ref, {key, task})}
            |> broadcast_and_store_run(key, run)

          {:reply, :ok, state}
        end

      %{status: :running} = run when slug == "conversation" ->
        case run.record.resource
             |> Ash.ActionInput.for_action(:message, %{agent: run.record.id, text: query})
             |> Ash.run_action() do
          {:ok, _} ->
            {:reply, :ok,
             broadcast_and_store_run(state, key, %{
               run
               | messages: run.messages ++ [%{role: :user, text: query}]
             })}

          {:error, error} ->
            {:reply, {:error, error_text(error)}, state}
        end

      _ ->
        {:reply, {:error, "Start an idle example before sending a prompt."}, state}
    end
  end

  def handle_call({:request, key, request, context, timeout}, from, state) do
    case state.runs[key] do
      %{status: :running} = run ->
        id = Ash.UUIDv7.generate()

        card =
          Map.merge(request, %{
            id: id,
            hook: context.hook,
            expires_at: System.system_time(:millisecond) + timeout
          })

        waiter = %{
          from: from,
          key: key,
          monitor: Process.monitor(elem(from, 0)),
          timer: Process.send_after(self(), {:request_expired, id}, timeout),
          deadline: System.monotonic_time(:millisecond) + timeout
        }

        state = put_in(state.requests[id], waiter)
        {:noreply, broadcast_and_store_run(state, key, %{run | requests: run.requests ++ [card]})}

      _ ->
        {:reply, {:error, :run_not_active}, state}
    end
  end

  def handle_call({:command, owner, slug, :respond, input}, _, state) do
    key = {owner, slug}

    case state.requests[input.interaction_id] do
      %{key: ^key, deadline: deadline} ->
        if System.monotonic_time(:millisecond) < deadline do
          {:reply, :ok,
           reply_and_remove_request(state, input.interaction_id, {:ok, input.response})}
        else
          {:reply, {:error, :request_expired},
           reply_and_remove_request(state, input.interaction_id, {:error, :timeout})}
        end

      _ ->
        {:reply, {:error, :request_not_pending}, state}
    end
  end

  def handle_call({:command, owner, slug, :spawn_node, input}, _, state) do
    run = state.runs[{owner, slug}]
    path = input.path
    snapshot = if run && run.status != :stopped, do: subtree(run.snapshot, path)

    resource =
      case input.kind do
        :agent -> AgentExamples.Worker
        :team -> AgentExamples.NestedTeam
      end

    coordinator =
      if snapshot && snapshot.team?,
        do: snapshot,
        else: run && subtree(run.snapshot, Enum.drop(path, -1))

    result =
      cond do
        is_nil(snapshot) ->
          {:error, "The selected parent is no longer active."}

        Enum.any?(coordinator.members, &(&1.name == input.name)) ->
          {:error,
           "A member named #{inspect(input.name)} already exists in this team. Choose another name."}

        true ->
          owner = if snapshot.team?, do: nil, else: member_key(coordinator, List.last(path))

          coordinator.resource
          |> Ash.ActionInput.for_action(:add_member, %{
            agent: coordinator.id,
            member: input.name,
            resource: resource,
            owner: owner
          })
          |> Ash.run_action()
      end

    case result do
      {:ok, _} ->
        {:reply, :ok, broadcast_and_store_run(state, {owner, slug}, %{run | error: nil})}

      {:error, reason} ->
        {:reply, {:error, error_text(reason)}, state}
    end
  end

  def handle_call({:command, owner, slug, action, input}, _, state) do
    key = {owner, slug}

    case state.runs[key] do
      %{status: status} = run when status != :stopped ->
        input = normalize_member_input(action, input, run.snapshot)

        case dispatch_command(run, action, input) do
          {:ok, _receipt} ->
            run = %{run | error: nil}

            state =
              if action == :cancel,
                do: reply_to_run_requests(state, key, {:error, :cancelled}),
                else: state

            run = %{run | requests: state.runs[key].requests}
            {:reply, :ok, broadcast_and_store_run(state, key, run)}

          {:error, reason} ->
            {:reply, {:error, Exception.message(Ash.Error.to_ash_error(reason))}, state}
        end

      _ ->
        {:reply, {:error, "Start the example first."}, state}
    end
  end

  def handle_call({:stop, owner, slug}, _, state) do
    key = {owner, slug}

    case state.runs[key] do
      %{status: status} = run when status != :stopped ->
        case (Map.get(run.record, :resource) || run.record.__struct__)
             |> Ash.ActionInput.for_action(:stop, %{agent: run.record})
             |> Ash.run_action() do
          {:ok, _receipt} ->
            state = reply_to_run_requests(state, key, {:error, :stopped})
            for {_ref, {^key, task}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
            tasks = Map.reject(state.tasks, fn {_, {task_key, _}} -> task_key == key end)

            state = retire_subscriptions(state, fn subscription -> subscription.key == key end)
            subscriptions = state.subscriptions

            run = %{run | status: :stopped, requests: []}

            {:reply, :ok,
             broadcast_and_store_run(
               %{state | tasks: tasks, subscriptions: subscriptions},
               key,
               run
             )}

          {:error, reason} ->
            {:reply, {:error, inspect(reason)}, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    apply_prompt_task_result(ref, result, state)
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Enum.find(state.requests, fn {_, waiter} -> waiter.monitor == ref end) do
      {id, _} -> {:noreply, reply_and_remove_request(state, id, {:error, :caller_stopped})}
      nil -> apply_prompt_task_result(ref, {:error, "Run failed: #{inspect(reason)}"}, state)
    end
  end

  def handle_info(
        {:aikido_subscription, ref, %{result: {:ok, snapshot}, signal_type: type}},
        state
      ) do
    case state.subscriptions[ref] do
      nil ->
        {:noreply, state}

      %{key: key, member: member, pid: pid} ->
        run = state.runs[key]

        path = Enum.flat_map(member || [], &[:children, &1])
        previous = if path == [], do: run.snapshot, else: get_in(run.snapshot, path)

        if is_nil(previous) || run.status == :stopped || snapshot_pid(run, member || []) != pid do
          {:noreply, state}
        else
          snapshot = Map.put(snapshot, :children, previous.children)
          snapshot = if path == [], do: snapshot, else: put_in(run.snapshot, path, snapshot)
          {snapshot, state} = watch_children(key, snapshot, [], state)
          state = reconcile_subscriptions(key, snapshot, state)

          type = if member, do: "#{Enum.join(member, "/")} · #{type}", else: type
          event = %{type: type, time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")}

          run = %{
            run
            | snapshot: snapshot,
              events: Enum.take([event | run.events], 80)
          }

          {:noreply, broadcast_and_store_run(state, key, run)}
        end
    end
  end

  def handle_info({:request_expired, id}, state),
    do: {:noreply, reply_and_remove_request(state, id, {:error, :timeout})}

  def handle_info(_, state), do: {:noreply, state}

  defp start_prompt_task(record, query, owner, slug) do
    Task.Supervisor.async_nolink(AgentExamples.WebTasks, fn ->
      AI.ask(record, query,
        timeout: 180_000,
        metadata: %{playground: %{owner: owner, slug: slug}}
      )
    end)
  end

  defp dispatch_command(%{record: %{resource: AgentExamples.Counter}} = run, action, input)
       when action in [:increase, :decrease] do
    definition =
      case action do
        :increase -> AgentExamples.Counter.Signals.Increase
        :decrease -> AgentExamples.Counter.Signals.Decrease
      end

    with {:ok, signal} <- definition.new(input) do
      Aikido.AgentServer.call(run.record.pid, signal, fn _ -> {:ok, :processed} end)
    end
  end

  defp dispatch_command(%{record: %{resource: AgentExamples.Counter}} = run, :notice, _input) do
    signal = Aikido.Signal.new!("counter.notice", %{message: "Observed by the wildcard route"})
    Aikido.AgentServer.call(run.record.pid, signal, fn _ -> {:ok, :processed} end)
  end

  defp dispatch_command(run, action, input) do
    run.record.resource
    |> Ash.ActionInput.for_action(action, Map.put(input, :agent, run.record.id))
    |> Ash.run_action()
  end

  defp create_run(_key, nil, _, state), do: {:reply, {:error, "Unknown example"}, state}

  defp create_run(key, example, options, state) do
    with {:ok, attributes} <- attributes(example, options),
         attributes = with_request_callback(example, attributes, key),
         {:ok, record} <-
           example.resource |> Ash.ActionInput.for_action(:start, attributes) |> Ash.run_action() do
      pid = record.pid

      {:ok, ref, snapshot} = subscribe_snapshot(pid)

      state = %{
        state
        | subscriptions: Map.put(state.subscriptions, ref, %{key: key, member: nil, pid: pid})
      }

      {snapshot, state} = watch_children(key, snapshot, [], state)

      run = %{
        record: record,
        requests: [],
        status: :ready,
        mode: options["mode"] || "offline",
        messages: [],
        snapshot: snapshot,
        events: [],
        error: nil
      }

      {:reply, {:ok, run}, broadcast_and_store_run(state, key, run)}
    else
      {:error, reason} -> {:reply, {:error, error_text(reason)}, state}
    end
  end

  defp watch_children(key, snapshot, path, state) do
    snapshot = %{
      snapshot
      | children: Map.take(snapshot.children, Enum.map(snapshot.members, & &1.name))
    }

    Enum.reduce(snapshot.members, {snapshot, state}, fn member, {snapshot, state} ->
      child_path = path ++ [member.name]

      known? =
        Enum.any?(state.subscriptions, fn {_, sub} ->
          sub.key == key && sub.member == child_path && sub[:pid] == member.pid
        end)

      {child, state} =
        if known? do
          {snapshot.children[member.name], state}
        else
          case subscribe_snapshot(member.pid) do
            {:ok, ref, child} ->
              {child,
               put_in(state.subscriptions[ref], %{key: key, member: child_path, pid: member.pid})}

            _ ->
              {nil, state}
          end
        end

      if child do
        {child, state} = watch_children(key, child, child_path, state)
        {put_in(snapshot.children[member.name], child), state}
      else
        {%{snapshot | children: Map.delete(snapshot.children, member.name)}, state}
      end
    end)
  end

  defp subscribe_snapshot(pid) do
    with {:ok, ref} <- Aikido.AgentServer.subscribe(pid, "**", &snapshot/1) do
      try do
        case Aikido.AgentServer.state(pid, &snapshot/1) do
          {:ok, snapshot} ->
            {:ok, ref, snapshot}

          error ->
            unsubscribe(pid, ref)
            error
        end
      catch
        :exit, reason ->
          unsubscribe(pid, ref)
          {:error, reason}
      end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp reconcile_subscriptions(key, snapshot, state) do
    desired = child_pids(snapshot, [])

    retire_subscriptions(state, fn sub ->
      sub.key == key && sub.member != nil && Map.get(desired, sub.member) != sub.pid
    end)
  end

  defp child_pids(snapshot, path) do
    Enum.reduce(snapshot.members, %{}, fn member, pids ->
      child_path = path ++ [member.name]
      pids = Map.put(pids, child_path, member.pid)

      case snapshot.children[member.name] do
        nil -> pids
        child -> Map.merge(pids, child_pids(child, child_path))
      end
    end)
  end

  defp retire_subscriptions(state, retired?) do
    {retired, retained} = Enum.split_with(state.subscriptions, fn {_, sub} -> retired?.(sub) end)
    Enum.each(retired, fn {ref, sub} -> unsubscribe(sub.pid, ref) end)
    %{state | subscriptions: Map.new(retained)}
  end

  defp unsubscribe(pid, ref) do
    Aikido.AgentServer.unsubscribe(pid, ref)
  catch
    :exit, _ -> :ok
  end

  defp snapshot_pid(run, []), do: run.record.pid

  defp snapshot_pid(run, path) do
    case subtree(run.snapshot, Enum.drop(path, -1)) do
      nil ->
        nil

      parent ->
        case Enum.find(parent.members, &(&1.name == List.last(path))) do
          nil -> nil
          member -> member.pid
        end
    end
  end

  @doc "Portable hook callback; per-run browser identity arrives in event metadata."
  def request(
        request,
        %{event: %{metadata: %{playground: %{owner: owner, slug: slug}}}} = context
      ) do
    request({owner, slug}, request, context)
  end

  defp with_request_callback(%{resource: AgentExamples.InteractiveAssistant}, attributes, _key) do
    callback = &__MODULE__.request/2
    hooks = Ash.Resource.Info.attribute(AgentExamples.InteractiveAssistant, :hooks).default
    Map.put(attributes, :hooks, Enum.map(hooks, &Map.put(&1, :request, callback)))
  end

  defp with_request_callback(_, attributes, _key), do: attributes

  defp attributes(example, options) do
    if Catalog.ai?(example) do
      with {:ok, model} <- model_attributes(example, options) do
        attributes =
          options
          |> ai_overrides()
          |> Map.merge(model)
          |> Map.put(:tools, example_tools(example, options))

        {:ok, attributes}
      end
    else
      {:ok, %{}}
    end
  end

  defp ai_overrides(options) do
    Enum.reduce([:system_prompt, :max_iterations], %{}, fn key, attributes ->
      case Map.fetch(options, Atom.to_string(key)) do
        {:ok, value} -> Map.put(attributes, key, value)
        :error -> attributes
      end
    end)
  end

  defp example_tools(example, options) do
    tools = AI.Tools.for_assistant()

    cond do
      options["lua"] == "true" -> tools ++ AI.Tools.for_lua()
      example.kind == :ai_team -> tools ++ [:team_roster, :spawn_worker, :delegate]
      true -> tools
    end
  end

  defp model_attributes(_example, %{"mode" => "live"} = options) do
    with key when is_binary(key) and key != "" <- System.get_env("ZAI_API_KEY"),
         [provider, id] when id != "" <- String.split(options["model"] || "", ":", parts: 2),
         true <- provider in ["zai", "zai_coder"] do
      {:ok,
       %{
         client: ReqLLM.Generation,
         model: %{provider: if(provider == "zai", do: :zai, else: :zai_coder), id: id}
       }}
    else
      _ -> {:error, "Live mode needs ZAI_API_KEY on the server and a model such as zai:glm-5.3."}
    end
  end

  defp model_attributes(example, _options) do
    attributes = AI.offline()

    attributes =
      if example.slug == "conversation",
        do: Map.put(attributes, :client, AI.StreamingClient),
        else: attributes

    {:ok, attributes}
  end

  defp snapshot(state) do
    resource = state.agent_module

    own = Map.get(state.agent.state, :state, %{})
    ai = Map.get(state.agent.state, :ai, %{})
    team = Map.get(state.agent.state, :team, %{})

    {:ok,
     %{
       id: state.id,
       resource: resource,
       team?: resource && !is_nil(Aikido.Agent.Info.team_config(resource)),
       children: %{},
       own:
         Map.take(own, [
           :count,
           :signals_seen,
           :items,
           :completed,
           :title,
           :status,
           :result,
           :error
         ]),
       journal: Map.get(Map.get(state.agent.state, :journal) || %{}, :entries, []),
       ai:
         Map.take(ai, [
           :status,
           :iteration,
           :result,
           :error,
           :hook_errors,
           :streaming_text,
           :streaming_thinking,
           :usage
         ])
         |> Map.put(:hook_messages, hook_injected_context_messages(ai)),
       todos: Map.get(Map.get(state.agent.state, :todos, %{}), :items, []),
       members: member_snapshots(team, resource),
       tasks: task_snapshots(team)
     }}
  end

  defp member_snapshots(team, resource) do
    fixed =
      if resource && !is_nil(Aikido.Agent.Info.team_config(resource)),
        do: Map.keys(Aikido.Agent.Info.team_config(resource).topology.nodes),
        else: []

    nodes = team |> Map.get(:topology, %{}) |> Map.get(:nodes, %{})

    team
    |> Map.get(:members, %{})
    |> Enum.map(fn {name, pid} ->
      node = nodes[name]

      %{
        name: to_string(name),
        key: name,
        pid: pid,
        owner: if(node && node.owner, do: to_string(node.owner), else: nil),
        dynamic: name not in fixed,
        alive: Process.alive?(pid)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp task_snapshots(team) do
    team
    |> Map.get(:tasks, %{})
    |> Map.values()
    |> Enum.map(&Map.take(&1, [:id, :member, :status, :result]))
  end

  defp hook_injected_context_messages(%{context: %ReqLLM.Context{} = context}) do
    context
    |> ReqLLM.Context.to_list()
    |> Enum.filter(&(&1.role == :user))
    |> Enum.flat_map(& &1.content)
    |> Enum.map(& &1.text)
    |> Enum.filter(&(is_binary(&1) && String.starts_with?(&1, "[Hook context:")))
  end

  defp hook_injected_context_messages(_), do: []

  defp subtree(nil, _), do: nil
  defp subtree(snapshot, []), do: snapshot
  defp subtree(snapshot, [name | rest]), do: subtree(snapshot.children[name], rest)

  def tree_options(nil), do: []
  def tree_options(run), do: [{"Root team", "[]"} | tree_options(run.snapshot, [])]

  defp tree_options(snapshot, path, display_path \\ []) do
    Enum.flat_map(snapshot.members, fn member ->
      child_path = path ++ [member.name]
      child = snapshot.children[member.name]

      display = display_path ++ ownership_path(snapshot.members, member)

      label =
        Enum.join(display, " / ") <> if(child && child.team?, do: " (team)", else: " (agent)")

      option = if child && member.alive, do: [{label, Jason.encode!(child_path)}], else: []

      option ++ if(child, do: tree_options(child, child_path, display), else: [])
    end)
  end

  defp ownership_path(_members, %{owner: nil, name: name}), do: [name]

  defp ownership_path(members, member) do
    parent = Enum.find(members, &(&1.name == member.owner))
    if(parent, do: ownership_path(members, parent), else: []) ++ [member.name]
  end

  defp normalize_member_input(action, %{member: name} = input, snapshot)
       when action in [:send, :remove_member, :stop_member, :ensure_member],
       do: %{input | member: member_key(snapshot, name)}

  defp normalize_member_input(_, input, _), do: input

  defp member_key(snapshot, name) do
    case Enum.find(snapshot.members, &(&1.name == to_string(name))) do
      nil -> name
      member -> member.key
    end
  end

  defp apply_prompt_task_result(ref, result, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{key, _task}, tasks} ->
        state = reply_to_run_requests(state, key, {:error, :run_finished})
        run = state.runs[key]

        run =
          case result do
            {:ok, answer} ->
              %{
                run
                | status: :completed,
                  messages: run.messages ++ [%{role: :assistant, text: answer}]
              }

            {:error, error} ->
              %{run | status: :failed, error: error_text(error)}
          end

        {:noreply, broadcast_and_store_run(%{state | tasks: tasks}, key, run)}
    end
  end

  defp reply_to_run_requests(state, key, result) do
    Enum.reduce(state.requests, state, fn {id, waiter}, state ->
      if waiter.key == key, do: reply_and_remove_request(state, id, result), else: state
    end)
  end

  defp reply_and_remove_request(state, id, result) do
    case Map.pop(state.requests, id) do
      {nil, _} ->
        state

      {waiter, requests} ->
        Process.cancel_timer(waiter.timer)
        Process.demonitor(waiter.monitor, [:flush])
        GenServer.reply(waiter.from, result)
        state = %{state | requests: requests}
        run = state.runs[waiter.key]

        broadcast_and_store_run(state, waiter.key, %{
          run
          | requests: Enum.reject(run.requests, &(&1.id == id))
        })
    end
  end

  defp broadcast_and_store_run(state, key, run) do
    Phoenix.PubSub.broadcast(
      AgentExamples.PubSub,
      @topic,
      {:run_updated, elem(key, 0), elem(key, 1)}
    )

    put_in(state.runs[key], run)
  end

  defp error_text(value) when is_binary(value), do: value
  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text(value), do: inspect(value)
end
