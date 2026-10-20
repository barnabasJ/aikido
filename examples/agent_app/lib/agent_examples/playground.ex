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
          task =
            Task.Supervisor.async_nolink(
              AgentExamples.WebTasks,
              fn -> AI.ask(run.record, query, timeout: 180_000) end
            )

          run = %{
            run
            | status: :running,
              error: nil,
              messages: run.messages ++ [%{role: :user, text: query}]
          }

          state =
            %{state | tasks: Map.put(state.tasks, task.ref, {key, task})} |> put_run(key, run)

          {:reply, :ok, state}
        end

      %{status: :running} = run when slug == "conversation" ->
        case Aikido.Ash.command(run.record, %{text: query}, action: :message) do
          {:ok, _} ->
            {:reply, :ok,
             put_run(state, key, %{run | messages: run.messages ++ [%{role: :user, text: query}]})}

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
        {:noreply, put_run(state, key, %{run | requests: run.requests ++ [card]})}

      _ ->
        {:reply, {:error, :run_not_active}, state}
    end
  end

  def handle_call({:command, owner, slug, :respond, input}, _, state) do
    key = {owner, slug}

    case state.requests[input.interaction_id] do
      %{key: ^key, deadline: deadline} ->
        if System.monotonic_time(:millisecond) < deadline do
          {:reply, :ok, finish_request(state, input.interaction_id, {:ok, input.response})}
        else
          {:reply, {:error, :request_expired},
           finish_request(state, input.interaction_id, {:error, :timeout})}
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

          with {:ok, record} <- Aikido.Ash.inspect(coordinator.resource, coordinator.id) do
            Aikido.Ash.command(
              record,
              %{member: input.name, resource: resource, owner: owner},
              action: :add_member
            )
          end
      end

    case result do
      {:ok, _} -> {:reply, :ok, put_run(state, {owner, slug}, %{run | error: nil})}
      {:error, reason} -> {:reply, {:error, error_text(reason)}, state}
    end
  end

  def handle_call({:command, owner, slug, action, input}, _, state) do
    key = {owner, slug}

    case state.runs[key] do
      %{status: status} = run when status != :stopped ->
        input = normalize_member_input(action, input, run.snapshot)

        case Aikido.Ash.command(run.record, input, action: action) do
          {:ok, _receipt} ->
            run = %{run | error: nil}

            state =
              if action == :cancel,
                do: finish_requests(state, key, {:error, :cancelled}),
                else: state

            run = %{run | requests: state.runs[key].requests}
            {:reply, :ok, put_run(state, key, run)}

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
        case Aikido.Ash.stop(run.record) do
          {:ok, _receipt} ->
            state = finish_requests(state, key, {:error, :stopped})
            for {_ref, {^key, task}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
            tasks = Map.reject(state.tasks, fn {_, {task_key, _}} -> task_key == key end)

            subscriptions =
              Map.reject(state.subscriptions, fn {_, subscription} -> subscription.key == key end)

            run = %{run | status: :stopped, requests: []}

            {:reply, :ok,
             put_run(%{state | tasks: tasks, subscriptions: subscriptions}, key, run)}

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
    finish_task(ref, result, state)
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    case Enum.find(state.requests, fn {_, waiter} -> waiter.monitor == ref end) do
      {id, _} -> {:noreply, finish_request(state, id, {:error, :caller_stopped})}
      nil -> finish_task(ref, {:error, "Run failed: #{inspect(reason)}"}, state)
    end
  end

  def handle_info(
        {:aikido_subscription, ref, %{result: {:ok, snapshot}, signal_type: type}},
        state
      ) do
    case state.subscriptions[ref] do
      nil ->
        {:noreply, state}

      %{key: key, member: member} ->
        run = state.runs[key]

        path = Enum.flat_map(member || [], &[:children, &1])
        previous = if path == [], do: run.snapshot, else: get_in(run.snapshot, path)

        if is_nil(previous) || run.status == :stopped do
          {:noreply, state}
        else
          snapshot = Map.put(snapshot, :children, previous.children)
          snapshot = if path == [], do: snapshot, else: put_in(run.snapshot, path, snapshot)
          {snapshot, state} = watch_children(key, snapshot, [], state)

          type = if member, do: "#{Enum.join(member, "/")} · #{type}", else: type
          event = %{type: type, time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")}

          run = %{
            run
            | snapshot: snapshot,
              events: Enum.take([event | run.events], 80)
          }

          {:noreply, put_run(state, key, run)}
        end
    end
  end

  def handle_info({:request_expired, id}, state),
    do: {:noreply, finish_request(state, id, {:error, :timeout})}

  def handle_info(_, state), do: {:noreply, state}

  defp create_run(_key, nil, _, state), do: {:reply, {:error, "Unknown example"}, state}

  defp create_run(key, example, options, state) do
    with {:ok, attributes} <- attributes(example, options),
         attributes = with_request_callback(example, attributes, key),
         {:ok, record} <- Aikido.Ash.start(example.resource, attributes) do
      pid = Aikido.whereis(Aikido.Default, record.id)
      {:ok, ref} = Aikido.AgentServer.subscribe(pid, "**", &snapshot/1)
      {:ok, snapshot} = Aikido.AgentServer.state(pid, &{:ok, elem(snapshot(&1), 1)})

      state = %{
        state
        | subscriptions: Map.put(state.subscriptions, ref, %{key: key, member: nil})
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

      {:reply, {:ok, run}, put_run(state, key, run)}
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
          with {:ok, ref} <- Aikido.AgentServer.subscribe(member.pid, "**", &snapshot/1),
               {:ok, child} <- Aikido.AgentServer.state(member.pid, &snapshot/1) do
            {child,
             put_in(state.subscriptions[ref], %{key: key, member: child_path, pid: member.pid})}
          else
            _ -> {nil, state}
          end
        end

      if child do
        {child, state} = watch_children(key, child, child_path, state)
        {put_in(snapshot.children[member.name], child), state}
      else
        {snapshot, state}
      end
    end)
  end

  defp with_request_callback(%{resource: AgentExamples.InteractiveAssistant}, attributes, key) do
    callback = fn request, context -> request(key, request, context) end
    hooks = Ash.Resource.Info.attribute(AgentExamples.InteractiveAssistant, :hooks).default
    Map.put(attributes, :hooks, Enum.map(hooks, &Map.put(&1, :request, callback)))
  end

  defp with_request_callback(_, attributes, _key), do: attributes

  defp attributes(example, options) do
    if Catalog.ai?(example) do
      overrides =
        Enum.reduce([:system_prompt, :max_iterations], %{}, fn key, attributes ->
          case Map.fetch(options, Atom.to_string(key)) do
            {:ok, value} -> Map.put(attributes, key, value)
            :error -> attributes
          end
        end)

      tools = AI.Tools.for_assistant()
      tools = if options["lua"] == "true", do: tools ++ AI.Tools.from_ash_ai(), else: tools

      tools =
        if example.kind == :ai_team && options["lua"] != "true" do
          tools ++ [:team_roster, :spawn_worker, :delegate]
        else
          tools
        end

      if options["mode"] == "live" do
        with key when is_binary(key) and key != "" <- System.get_env("ZAI_API_KEY"),
             [provider, id] when id != "" <- String.split(options["model"] || "", ":", parts: 2),
             true <- provider in ["zai", "zai_coder"] do
          {:ok,
           Map.merge(overrides, %{
             tools: tools,
             client: ReqLLM.Generation,
             model: %{provider: if(provider == "zai", do: :zai, else: :zai_coder), id: id}
           })}
        else
          _ ->
            {:error, "Live mode needs ZAI_API_KEY on the server and a model such as zai:glm-5.3."}
        end
      else
        attributes = AI.offline(Map.put(overrides, :tools, tools))

        attributes =
          if example.slug == "conversation",
            do: Map.put(attributes, :client, AI.StreamingClient),
            else: attributes

        {:ok, attributes}
      end
    else
      {:ok, %{}}
    end
  end

  defp snapshot(state) do
    resource = state.agent_module

    fixed =
      if resource && !is_nil(Aikido.Dsl.Agent.Info.team_config(resource)),
        do: Map.keys(Aikido.Dsl.Agent.Info.team_config(resource).topology.nodes),
        else: []

    own = Map.get(state.agent.state, :state, %{})
    ai = Map.get(state.agent.state, :ai, %{})
    team = Map.get(state.agent.state, :team, %{})

    members =
      for {name, pid} <- Map.get(team, :members, %{}) do
        nodes = team |> Map.get(:topology, %{}) |> Map.get(:nodes, %{})
        node = nodes[name]

        %{
          name: to_string(name),
          key: name,
          pid: pid,
          owner: if(node && node.owner, do: to_string(node.owner), else: nil),
          dynamic: name not in fixed,
          alive: Process.alive?(pid)
        }
      end

    tasks =
      team
      |> Map.get(:tasks, %{})
      |> Map.values()
      |> Enum.map(&Map.take(&1, [:id, :member, :status, :result]))

    {:ok,
     %{
       id: state.id,
       resource: resource,
       team?: resource && !is_nil(Aikido.Dsl.Agent.Info.team_config(resource)),
       children: %{},
       own: Map.take(own, [:count, :items, :completed, :title, :status, :result, :error]),
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
         |> Map.put(:hook_messages, hook_messages(ai)),
       todos: Map.get(Map.get(state.agent.state, :todos, %{}), :items, []),
       members: Enum.sort_by(members, & &1.name),
       tasks: tasks
     }}
  end

  defp hook_messages(%{context: %ReqLLM.Context{} = context}) do
    context
    |> ReqLLM.Context.to_list()
    |> Enum.filter(&(&1.role == :user))
    |> Enum.flat_map(& &1.content)
    |> Enum.map(& &1.text)
    |> Enum.filter(&(is_binary(&1) && String.starts_with?(&1, "[Hook context:")))
  end

  defp hook_messages(_), do: []

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

  defp normalize_member_input(:send, %{data: %{member: name} = data} = input, snapshot),
    do: %{input | data: %{data | member: member_key(snapshot, name)}}

  defp normalize_member_input(action, %{member: name} = input, snapshot)
       when action in [:remove_member, :stop_member, :ensure_member],
       do: %{input | member: member_key(snapshot, name)}

  defp normalize_member_input(_, input, _), do: input

  defp member_key(snapshot, name) do
    case Enum.find(snapshot.members, &(&1.name == to_string(name))) do
      nil -> name
      member -> member.key
    end
  end

  defp finish_task(ref, result, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{key, _task}, tasks} ->
        state = finish_requests(state, key, {:error, :run_finished})
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

        {:noreply, put_run(%{state | tasks: tasks}, key, run)}
    end
  end

  defp finish_requests(state, key, result) do
    Enum.reduce(state.requests, state, fn {id, waiter}, state ->
      if waiter.key == key, do: finish_request(state, id, result), else: state
    end)
  end

  defp finish_request(state, id, result) do
    case Map.pop(state.requests, id) do
      {nil, _} ->
        state

      {waiter, requests} ->
        Process.cancel_timer(waiter.timer)
        Process.demonitor(waiter.monitor, [:flush])
        GenServer.reply(waiter.from, result)
        state = %{state | requests: requests}
        run = state.runs[waiter.key]
        put_run(state, waiter.key, %{run | requests: Enum.reject(run.requests, &(&1.id == id))})
    end
  end

  defp put_run(state, key, run) do
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
