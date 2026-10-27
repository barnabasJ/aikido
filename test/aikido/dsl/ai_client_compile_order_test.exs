defmodule AikidoTest.AIClientCompileOrder.Instance do
  @moduledoc false
  use Aikido, otp_app: :aikido
end

defmodule AikidoTest.AIClientCompileOrderTest do
  # The runtime test uses a fixed instance; compilation tests load temporary modules.
  use ExUnit.Case, async: false
  require Spark.Test

  @moduletag :tmp_dir
  @compile_timeout 15_000

  test "a clean sibling client remains unloaded until its resource finishes compiling", %{
    tmp_dir: dir
  } do
    {resource, client} = compile_pair!(dir, false)
    attribute = Ash.Resource.Info.attribute(resource, :client)
    assert attribute.type == Ash.Type.Module
    assert attribute.default == {Function, :identity, [client]}
  end

  test "a configured sibling client may refer back to its resource without a forced compile wait",
       %{tmp_dir: dir} do
    {resource, client} = compile_pair!(dir, true)
    assert apply(resource, :client_reference, []) == client
    assert apply(client, :resource, []) == resource
    assert apply(client, :round_trip, []) == client
  end

  test "a missing configured module reports the native postcompile ai.client diagnostic" do
    resource = unique_module("MissingClientResource")
    missing = unique_module("MissingConfiguredClient")
    assert :code.is_loaded(missing) == false

    on_exit(fn -> unload([resource]) end)

    errors =
      Spark.Test.dsl_errors do
        Code.compile_string(resource_source(resource, missing, false))
      end

    assert :code.is_loaded(resource) != false

    assert [{^resource, [%Spark.Error.DslError{path: [:ai, :client], message: message}]}] = errors
    assert message =~ "ai.client must resolve to an available module"
    assert message =~ inspect(missing)
  end

  test "an explicit nil configured client reports the native postcompile ai.client diagnostic" do
    resource = unique_module("NilClientResource")
    assert :code.is_loaded(resource) == false
    on_exit(fn -> unload([resource]) end)

    errors =
      Spark.Test.dsl_errors do
        Code.compile_string(resource_source(resource, nil, false))
      end

    assert :code.is_loaded(resource) != false

    assert [{^resource, [%Spark.Error.DslError{path: [:ai, :client], message: message}]}] = errors
    assert message == "ai.client must resolve to an available module, got: nil"
  end

  test "native create and runtime initialization materialize defaults and preserve module overrides",
       %{tmp_dir: dir} do
    {resource, client} = compile_pair!(dir, false)

    start_supervised!(
      {AikidoTest.AIClientCompileOrder.Instance, durable: [data_dir: Path.join(dir, "durable")]}
    )

    # A raw schema struct intentionally cannot evaluate a lazy default.
    assert Map.fetch!(struct(resource), :client) == nil
    created = Ash.create!(resource, %{}, action: :create)
    assert created.client == client
    initialized = action!(resource, :initialize, %{id: "initialize-default", state: %{}})
    assert initialized.state.own.client == client
    assert runtime_clients(resource, %{}) == {client, client}

    override = ReqLLM.Generation
    assert Ash.create!(resource, %{client: override}, action: :create).client == override
    assert runtime_clients(resource, %{client: override}) == {override, override}

    missing = unique_module("MissingOverride")
    assert :code.is_loaded(missing) == false

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(resource, %{client: missing}, action: :create)

    input = Ash.ActionInput.for_action(resource, :start, %{id: "invalid-client", client: missing})
    refute input.valid?
    assert {:error, %Ash.Error.Invalid{}} = Ash.run_action(input)
  end

  defp compile_pair!(directory, cyclic?) do
    resource = unique_module("Resource")
    client = unique_module("Client")
    assert :code.is_loaded(client) == false
    assert :code.is_loaded(resource) == false
    owner = self()
    on_exit(fn -> unload([resource, client]) end)
    resource_path = Path.join(directory, "resource.ex")
    client_path = Path.join(directory, "client.ex")
    File.write!(resource_path, resource_source(resource, client, cyclic?))
    File.write!(client_path, client_source(resource, client, owner, cyclic?))

    task =
      Task.async(fn ->
        Kernel.ParallelCompiler.compile([resource_path, client_path],
          return_diagnostics: true,
          max_concurrency: 2,
          each_module: fn _file, module, _binary ->
            if module == resource, do: send(owner, {:resource_compiled, resource})
          end
        )
      end)

    compiler =
      receive do
        {:client_waiting, ^client, pid} -> pid
      after
        @compile_timeout ->
          Task.shutdown(task, :brutal_kill)
          flunk("sibling client did not enter its compile barrier")
      end

    try do
      # Release only after the resource has compiled while its client is unavailable.
      assert_receive {:resource_compiled, ^resource}, @compile_timeout
      assert :code.is_loaded(client) == false
      send(compiler, {:release_client, client})

      assert {:ok, modules, %{compile_warnings: [], runtime_warnings: []}} =
               Task.await(task, @compile_timeout)

      assert resource in modules
      assert client in modules
      on_exit(fn -> unload(modules) end)
      {resource, client}
    after
      send(compiler, {:release_client, client})

      if Process.alive?(task.pid) do
        Task.yield(task, @compile_timeout) || Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp resource_source(resource, client, cyclic?) do
    reference =
      if cyclic? do
        "@spec client_reference() :: module()\ndef client_reference, do: #{inspect(client)}"
      else
        ""
      end

    """
    defmodule #{inspect(resource)} do
      use Ash.Resource,
        data_layer: :embedded,
        domain: Aikido.RuntimeDomain,
        extensions: [Aikido.Agent.Extension, Aikido.AI.Extension]

      agent do
        name "client_compile_order"
        instance AikidoTest.AIClientCompileOrder.Instance
        path :own
        persistence :temporary
      end

      ai do
        client #{inspect(client)}
      end

      actions do
        defaults [:read, create: :*]
      end

      #{reference}
    end
    """
  end

  defp client_source(resource, client, owner, cyclic?) do
    reference =
      if cyclic? do
        """
        @resource #{inspect(resource)}
        @spec resource() :: module()
        def resource, do: @resource
        @spec round_trip() :: module()
        def round_trip, do: @resource.client_reference()
        """
      else
        ""
      end

    """
    defmodule #{inspect(client)} do
      send(:erlang.list_to_pid(~c"#{:erlang.pid_to_list(owner)}"),
        {:client_waiting, __MODULE__, self()})
      receive do
        {:release_client, __MODULE__} -> :ok
      after
        #{@compile_timeout * 2} -> raise "client compile barrier was not released"
      end

      # Custom model clients need no newly declared behaviour for this contract.
      @spec generate_text(model :: term(), messages :: term(), options :: keyword()) :: {:error, :not_invoked}
      def generate_text(_model, _messages, _options), do: {:error, :not_invoked}
      @spec stream_text(model :: term(), messages :: term(), options :: keyword()) :: {:error, :not_invoked}
      def stream_text(_model, _messages, _options), do: {:error, :not_invoked}
      #{reference}
    end
    """
  end

  defp runtime_clients(resource, attributes) do
    reference = action!(resource, :start, Map.put(attributes, :id, Ash.UUIDv7.generate()))

    try do
      {:ok, clients} =
        Aikido.AgentServer.state(reference.pid, fn runtime ->
          {:ok, {runtime.agent.state.own.client, runtime.agent.state.ai.client}}
        end)

      clients
    after
      action!(resource, :stop, %{agent: reference})
    end
  end

  defp action!(resource, action, arguments) do
    resource |> Ash.ActionInput.for_action(action, arguments) |> Ash.run_action!()
  end

  defp unique_module(kind),
    do: Module.concat(__MODULE__, "#{kind}#{System.unique_integer([:positive])}")

  defp unload(modules) do
    Enum.each(modules, fn module ->
      :code.purge(module)
      :code.delete(module)
    end)
  end
end
