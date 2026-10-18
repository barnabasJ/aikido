defmodule Aikido.Slices.Identity.Actions do
  @moduledoc "Native Ash state-transition actions for the identity slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :ensure, Aikido.ActionResult do
      argument :state, :term

      argument :profile, :map,
        description: "Initial profile map for new identities.",
        default: %{age: nil}

      description "Initialize identity state if missing."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case ensure_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :evolve, Aikido.ActionResult do
      argument :state, :term
      argument :days, :integer, description: "Days of simulated time to add", default: 0
      argument :years, :integer, description: "Years of simulated time to add", default: 0
      description "Evolve agent identity over simulated time"

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case evolve_reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end

    action :update_profile, Aikido.ActionResult do
      argument :state, :term

      argument :profile, :map,
        description: "Partial profile map to merge into the identity.",
        allow_nil?: false

      description "Merge a partial profile map into the identity profile."

      run fn input, _context ->
        runtime = input.context[:aikido] || %{}
        params = Map.delete(input.arguments, :state)
        signal = Map.fetch!(runtime, :signal)
        signal = %{signal | data: Map.merge(signal.data || %{}, params)}

        case update_profile_reduce(
               signal,
               input.arguments.state,
               runtime[:action_opts] || %{},
               runtime
             ) do
          {:ok, state, directives} ->
            Aikido.ActionResult.new(state: state, directives: directives)

          {:error, _} = error ->
            error

          other ->
            {:error, "Unexpected return shape: #{inspect(other)}"}
        end
      end
    end
  end

  defp ensure_reduce(%Jido.Signal{data: data}, slice, _opts, _ctx) do
    case slice do
      %Aikido.Slices.Identity.State{} = identity -> {:ok, identity, []}
      _ -> {:ok, Aikido.Slices.Identity.State.new(Map.to_list(data)), []}
    end
  end

  defp evolve_reduce(%Jido.Signal{data: params}, slice, _opts, _ctx) do
    identity = slice || Aikido.Slices.Identity.State.new()
    evolved = Aikido.Slices.Identity.State.evolve(identity, Map.to_list(params))
    {:ok, evolved, []}
  end

  defp update_profile_reduce(%Jido.Signal{data: %{profile: profile}}, slice, _opts, _ctx) do
    identity = update_profile_ensure_identity(slice)
    {:ok, Aikido.Slices.Identity.State.update_profile(identity, profile), []}
  end

  defp update_profile_ensure_identity(%Aikido.Slices.Identity.State{} = identity) do
    identity
  end

  defp update_profile_ensure_identity(_) do
    Aikido.Slices.Identity.State.new()
  end
end
