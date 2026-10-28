defmodule Aikido.Durable do
  @moduledoc """
  DurableServer supervision for keyed Aikido agents.

  `ensure_started/3` activates or restores a key. DurableServer owns discovery,
  storage claims, synchronization, and recovery. The default backend is EKV on
  local disk. Configure `:backend` for shared EKV or object storage; local disk
  alone does not protect against loss of the machine or its volume.
  """
  use Supervisor

  @options [
    name: [type: :atom, required: true],
    agent: [type: :atom],
    agent_opts: [type: :keyword_list, default: []],
    scope_adapter: [type: :module],
    aikido: [type: :atom],
    partition: [type: :any],
    permanent: [type: :boolean, default: true],
    data_dir: [type: :string],
    ekv_options: [type: :keyword_list, default: []],
    prefix: [type: :string],
    backend: [type: :any],
    durable_options: [type: :keyword_list, default: []]
  ]

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts),
    do:
      Supervisor.start_link(__MODULE__, Spark.Options.validate!(opts, @options),
        name: supervisor_name(opts[:name])
      )

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    {stores, backend} = storage_children(opts, name)
    durable_opts = durable_supervisor_options(opts, name, backend)
    Supervisor.init(stores ++ [{DurableServer.Supervisor, durable_opts}], strategy: :rest_for_one)
  end

  defp storage_children(opts, name) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} -> {[], backend}
      :error -> local_ekv_storage(opts, name)
    end
  end

  defp local_ekv_storage(opts, name) do
    ekv = Module.concat(name, Store)

    directory =
      Keyword.get_lazy(opts, :data_dir, fn ->
        Path.join([File.cwd!(), "_build", "aikido_durable", Atom.to_string(name)])
      end)

    store_options =
      [cluster_size: 1, node_id: "local", shards: 1]
      |> Keyword.merge(opts[:ekv_options])
      |> Keyword.merge(name: ekv, data_dir: directory)

    {[{EKV, store_options}], {DurableServer.Backends.EKVStore, name: ekv}}
  end

  defp durable_supervisor_options(opts, name, backend) do
    durable = Keyword.get(opts, :durable_options, [])
    info = Map.put(durable[:init_info] || %{}, :aikido_config, activation_defaults(opts))

    Keyword.merge(durable,
      name: name,
      prefix: Keyword.get(opts, :prefix, "aikido/#{name}/"),
      backend: backend,
      init_info: info
    )
  end

  defp activation_defaults(opts) do
    %{
      agent: opts[:agent],
      scope_adapter: opts[:scope_adapter],
      agent_opts: Keyword.get(opts, :agent_opts, []),
      aikido:
        Keyword.get(
          opts,
          :aikido,
          Keyword.get(Keyword.get(opts, :agent_opts, []), :aikido, Aikido.Default)
        ),
      partition: opts[:partition],
      permanent: Keyword.get(opts, :permanent, true)
    }
  end

  @doc "Activates an identity with native DurableServer caller/placement options as the final argument."
  def start(name, key, opts \\ [], start_options \\ []),
    do: activate(name, key, opts, start_options, :start_child)

  def ensure_started(name, key, opts \\ [], start_options \\ []),
    do: ensure_activation(name, key, opts, start_options)

  defp ensure_activation(name, key, opts, start_options) do
    validate_activation_context!(start_options)

    case lookup(name, key, opts) do
      {:ok, pid} -> {:ok, pid}
      :error -> activate(name, key, opts, start_options, :ensure_started_child)
    end
  end

  defp activate(name, key, opts, start_options, operation) do
    config = config(name)
    partition = Keyword.get(opts, :partition, config.partition)
    agent = Keyword.get(opts, :agent, config.agent)

    agent_opts =
      config.agent_opts
      |> Keyword.merge(Keyword.get(opts, :agent_opts, []))
      |> Keyword.merge(
        agent_module: agent,
        id: agent_id(key),
        aikido: config.aikido,
        partition: partition,
        initial_state: Keyword.get(opts, :initial_state, %{}) || %{},
        durable_server: name,
        durable_key: key
      )

    {initialization_options, agent_opts} = Keyword.pop(agent_opts, :initialization_options, [])
    initialization_options = Map.new(initialization_options)

    initialization_options =
      Ash.Scope.to_opts(initialization_options,
        context: Map.get(initialization_options, :context, %{})
      )

    validate_activation_context!(start_options)
    start_options = Keyword.delete(start_options, :init_context)
    identity = Aikido.Durable.ScopeAdapter.identity(agent_opts)

    with {:ok, initial} <-
           activation_input(name, key, config, agent_opts, initialization_options, identity, opts) do
      spec =
        {Aikido.Durable.AgentServer, key: storage_key(key, partition), initial_state: initial}

      case apply(DurableServer.Supervisor, operation, [name, spec, start_options]) do
        {:ok, {pid, _}} -> {:ok, pid}
        {:error, {:already_started, {pid, _}}} -> {:error, {:already_started, pid}}
        {:error, _} = error -> error
      end
    end
  end

  defp activation_input(name, key, config, options, scope, identity, opts) do
    native = DurableServer.Supervisor.__get_config__(name)
    request = %{key: storage_key(key, options[:partition]), prefix: native.prefix}

    case DurableServer.fetch_stored_state(name, request, consistent: true) do
      {:ok, %DurableServer.StoredState{meta: %{module: Aikido.Durable.AgentServer} = meta}} ->
        if DurableServer.Meta.deleting?(meta),
          do: prepare_activation(config, options, scope, identity, opts),
          else: {:ok, %{require_existing?: true}}

      {:ok, _other_resource} ->
        {:error, :different_resource}

      {:error, :not_found} ->
        prepare_activation(config, options, scope, identity, opts)

      {:error, reason} ->
        {:error, {:snapshot_read_failed, reason}}
    end
  end

  defp prepare_activation(config, options, scope, identity, opts) do
    if is_nil(options[:agent_module]),
      do: {:error, :agent_module_required},
      else: prepare_fresh_activation(config, options, scope, identity, opts)
  end

  defp prepare_fresh_activation(config, options, scope, identity, opts) do
    permanent = Keyword.get(opts, :permanent, config.permanent)

    if adapter = config.scope_adapter do
      with {:ok, attributes, credential} <-
             adapter.prepare(options[:initial_state], scope, identity),
           {:ok, attributes, paths} <-
             Aikido.Durable.Codec.externalize_initial(attributes, options[:agent_module], true) do
        {:ok,
         %{
           options: Aikido.Durable.Snapshot.boot_options(options),
           parent: bootstrap_parent(options[:parent]),
           permanent: permanent,
           agent: {:uninitialized, attributes},
           bootstrap_codecs: paths,
           initial?: true,
           credential: credential
         }}
      end
    else
      if Keyword.get(scope, :actor) || Keyword.get(scope, :tenant) ||
           scope[:context] not in [nil, %{}] do
        {:error, :scope_adapter_required}
      else
        with {:ok, attributes, paths} <-
               Aikido.Durable.Codec.externalize_initial(
                 options[:initial_state],
                 options[:agent_module]
               ) do
          {:ok,
           %{
             options: Aikido.Durable.Snapshot.boot_options(options),
             parent: bootstrap_parent(options[:parent]),
             permanent: permanent,
             agent: {:uninitialized, attributes},
             bootstrap_codecs: paths,
             initial?: true,
             credential: nil
           }}
        end
      end
    end
  end

  defp bootstrap_parent(nil), do: nil
  defp bootstrap_parent(parent), do: Map.take(parent, [:id, :partition, :tag, :meta])

  defp validate_activation_context!(options) do
    case Keyword.fetch(options, :init_context) do
      {:ok, value} when not is_map(value) ->
        raise ArgumentError, ":init_context must be a map"

      {:ok, _value} ->
        raise ArgumentError, "Use a configured durable scope adapter for activation authority"

      :error ->
        :ok
    end
  end

  def lookup(name, key, opts \\ []) do
    partition = Keyword.get(opts, :partition, config(name).partition)

    case DurableServer.Supervisor.lookup(name, storage_key(key, partition)) do
      {pid, _} -> {:ok, pid}
      nil -> :error
    end
  end

  @doc false
  def restored?(name, key, opts \\ []) do
    partition = Keyword.get(opts, :partition, config(name).partition)

    case DurableServer.Supervisor.lookup(name, storage_key(key, partition)) do
      {_pid, %{restored?: restored?}} -> restored?
      _ -> false
    end
  end

  @doc "Stop by logical key or PID, retaining or deleting the snapshot according to the agent's persistence setting."
  def stop(name, key_or_pid, opts \\ [])

  def stop(_name, pid, opts) when is_pid(pid) do
    with {:ok, {supervisor, key, partition, keep_snapshot?}} <-
           Aikido.AgentServer.state(pid, fn runtime ->
             {:ok,
              {runtime.durable_server, runtime.durable_key, runtime.partition,
               keep_snapshot?(runtime.agent_module)}}
           end),
         :ok <- Aikido.AgentServer.prepare_stop(pid, :normal, Keyword.get(opts, :scope, %{})) do
      if keep_snapshot?,
        do: DurableServer.Supervisor.terminate_child_permanent(supervisor, pid),
        else: delete(supervisor, key, partition: partition)
    end
  end

  def stop(name, key, opts) do
    case lookup(name, key, opts) do
      {:ok, pid} -> stop(name, pid, opts)
      :error -> {:error, :not_found}
    end
  end

  @doc "Stop an agent and delete its snapshot, including when the agent is already stopped."
  def delete(name, logical_key, opts \\ []) do
    config = config(name)
    partition = Keyword.get(opts, :partition, config.partition)
    storage_key = storage_key(logical_key, partition)

    with :ok <- validate_delete_target(name, storage_key, opts[:agent]) do
      DurableServer.Supervisor.terminate_and_delete_child(name, storage_key)
    end
  end

  @doc "Read a saved logical parent without activating the child."
  def parent_binding(name, logical_key, opts \\ []) do
    partition = Keyword.get(opts, :partition, config(name).partition)

    with {:ok, info} <-
           DurableServer.Supervisor.get_server_info(name, storage_key(logical_key, partition)),
         saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state),
         %{id: parent_id} = parent <- Map.get(saved, :parent) do
      {:ok,
       %{
         parent_id: parent_id,
         parent_partition: parent.partition,
         tag: parent.tag,
         meta: parent.meta
       }}
    else
      _ -> :error
    end
  end

  defp validate_delete_target(_name, _key, nil), do: :ok

  defp validate_delete_target(name, key, expected_agent) do
    with {:ok, info} <- DurableServer.Supervisor.get_server_info(name, key),
         true <- info.module == Aikido.Durable.AgentServer || {:error, :different_resource} do
      saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)

      if saved.options[:agent_module] == expected_agent,
        do: :ok,
        else: {:error, :different_resource}
    end
  end

  @doc false
  def keep_snapshot?(agent_module) do
    Spark.Dsl.Extension.get_opt(agent_module, [:agent], :persistence, :permanent) == :permanent
  end

  def supervisor_name(name), do: Module.concat(name, Supervisor)

  @doc "Lists active logical keys and their current local or remote processes."
  def members(name, opts \\ []) do
    partition = Keyword.get(opts, :partition, config(name).partition)

    DurableServer.Supervisor.global_members(name)
    |> Enum.flat_map(fn {_key, {pid, meta}} ->
      case meta.user_meta do
        %{partition: ^partition, key: key} -> [{key, pid}]
        _ -> []
      end
    end)
  end

  defp config(name), do: DurableServer.Supervisor.__get_config__(name).init_info.aikido_config

  @doc false
  def storage_key(key, partition),
    do: "agent/" <> Base.url_encode64(:erlang.term_to_binary({partition, key}), padding: false)

  @doc false
  def agent_id(key) when is_binary(key), do: key

  def agent_id(key),
    do:
      "key_" <>
        Base.url_encode64(:crypto.hash(:sha256, :erlang.term_to_binary(key)), padding: false)
end
