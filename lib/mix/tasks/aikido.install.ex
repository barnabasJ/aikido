if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Aikido.Install do
    @shortdoc "Installs Aikido in your project"

    @moduledoc """
    Installs and configures Aikido in your project.

        $ mix aikido.install

    This task will:

    1. Add Aikido configuration to `config/config.exs`
    2. Create a `<YourApp>.Aikido` instance module
    3. Optionally add `<YourApp>.Aikido` to your application's supervision tree
    4. Optionally generate an example agent

    ## Options

    - `--no-supervisor` - Skip adding Aikido instance to the supervision tree
    - `--example` - Generate an example agent module

    ## Examples

        $ mix aikido.install
        $ mix aikido.install --example
        $ mix aikido.install --no-supervisor
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Application
    alias Igniter.Project.Config
    alias Igniter.Project.Module, as: IgniterModule

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :aikido,
        adds_deps: [],
        installs: [],
        schema: [
          no_supervisor: :boolean,
          example: :boolean
        ],
        defaults: [
          no_supervisor: false,
          example: false
        ],
        example: "mix aikido.install"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      app_name = Application.app_name(igniter)
      aikido_module = Module.concat([Macro.camelize(to_string(app_name)), "Aikido"])
      aikido_module_contents = "use Aikido, otp_app: #{inspect(app_name)}"

      igniter =
        igniter
        |> IgniterModule.find_and_update_or_create_module(
          aikido_module,
          aikido_module_contents,
          fn zipper -> {:ok, zipper} end
        )
        |> Config.configure_new(
          "config.exs",
          app_name,
          [aikido_module],
          max_tasks: 1000,
          agent_pools: []
        )

      igniter =
        if options[:no_supervisor] do
          igniter
        else
          Application.add_new_child(
            igniter,
            aikido_module,
            after: [Ecto.Repo, Phoenix.PubSub]
          )
        end

      igniter =
        if options[:example] do
          example_module =
            Module.concat([Macro.camelize(to_string(app_name)), "Agents", "Example"])

          Igniter.compose_task(igniter, "aikido.gen.agent", [inspect(example_module)])
        else
          igniter
        end

      igniter
    end
  end
else
  defmodule Mix.Tasks.Aikido.Install do
    @moduledoc "Installs Aikido. Should be run with `mix igniter.install aikido`"
    @shortdoc @moduledoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'aikido.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
