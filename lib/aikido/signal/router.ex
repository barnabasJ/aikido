# Adapted from Jido Signal 3.0.0-beta.5 router.ex and router/route.ex (Apache-2.0).
# Copyright 2026 Mike Hostetler <mike.hostetler@gmail.com>.
# Aikido modifications: native Spark validation, generic envelopes, reduced API,
# existing Aikido errors, and no upstream signal schemas or Router DSL.
# See NOTICE for source provenance and adaptation details.
defmodule Aikido.Signal.Router do
  @moduledoc """
  Immutable whole-path signal routing for native agent and slice declarations.

  Exact paths precede `*` paths, which precede `**` paths. Within each class,
  positional specificity, priority and declaration order determine target order.
  `*` consumes one segment; `**` consumes zero or more. All matching declarations
  contribute targets. Predicates receive the original envelope and must return
  `true`; a raising, throwing or exiting predicate does not match.

  Routing needs only a binary `type` field and imposes no payload or scope schema.
  Subscription patterns can be compiled once with `compile_pattern/1` after
  validation and reused with `matches_compiled?/2`.
  """

  alias Aikido.Signal.Router.Index

  @empty_wildcard_index %{
    id: 0,
    exact: %{},
    single: nil,
    multi: nil,
    terminals: [],
    globstar?: false
  }
  defstruct exact_index: %{}, wildcard_index: @empty_wildcard_index

  @type t :: %__MODULE__{exact_index: map(), wildcard_index: map()}
  @type compiled_pattern :: String.t() | tuple()

  @route_schema [
    path: [type: :string, required: true],
    target: [type: :any, required: true],
    priority: [type: {:in, Enum.to_list(-100..100)}, default: 0],
    match: [type: {:fun, 1}]
  ]

  @doc "Constructs a router from existing route tuples without executing predicates."
  @spec new(list()) :: {:ok, t()} | {:error, Exception.t()}
  def new(routes) when is_list(routes) do
    with {:ok, normalized} <- normalize_routes(routes) do
      {:ok, Index.new(normalized)}
    end
  end

  def new(routes), do: invalid_route(routes)

  @doc "Constructs a router, raising its structured validation error on failure."
  @spec new!(list()) :: t()
  def new!(routes) do
    case new(routes) do
      {:ok, router} -> router
      {:error, error} -> raise error
    end
  end

  @doc "Returns every matching target in precedence order."
  @spec route(t(), map()) :: {:ok, list()} | {:error, Aikido.Error.RoutingError.t()}
  def route(%__MODULE__{} = router, %{type: type} = signal) when is_binary(type) do
    case Index.lookup(router, type, signal) do
      [] ->
        {:error,
         Aikido.Error.routing_error("No matching handlers found for signal",
           details: %{signal_type: type, reason: :no_handlers_found}
         )}

      targets ->
        {:ok, targets}
    end
  end

  def route(%__MODULE__{}, signal) do
    {:error,
     Aikido.Error.routing_error("Signal type must be a string",
       details: %{signal: signal, reason: :invalid_signal_type}
     )}
  end

  @doc "Validates the shared route/subscription path grammar."
  @spec validate_pattern(term()) :: {:ok, String.t()} | {:error, Aikido.Error.RoutingError.t()}
  def validate_pattern(pattern) when is_binary(pattern) do
    segments = String.split(pattern, ".")

    valid? =
      Enum.all?(segments, &(&1 in ["*", "**"] or String.match?(&1, ~r/\A[a-zA-Z0-9_-]+\z/))) and
        not Enum.any?(Enum.chunk_every(segments, 2, 1, :discard), &(&1 == ["**", "**"]))

    if valid?, do: {:ok, pattern}, else: invalid_pattern(pattern)
  end

  def validate_pattern(pattern), do: invalid_pattern(pattern)

  @doc "Compiles an already validated pattern for repeated subscription matching."
  @spec compile_pattern(String.t()) :: compiled_pattern()
  defdelegate compile_pattern(pattern), to: Index

  @doc "Matches a signal type against a previously validated, compiled pattern."
  @spec matches_compiled?(String.t(), compiled_pattern()) :: boolean()
  defdelegate matches_compiled?(type, pattern), to: Index

  defp normalize_routes(routes) do
    routes
    |> Enum.reduce_while({:ok, []}, fn route, {:ok, normalized} ->
      case normalize(route) do
        {:ok, entry} -> {:cont, {:ok, [entry | normalized]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize({path, target}), do: validate_route(path: path, target: target)

  defp normalize({path, target, priority}) when is_integer(priority),
    do: validate_route(path: path, target: target, priority: priority)

  defp normalize({path, match, target}) when is_function(match, 1),
    do: validate_route(path: path, target: target, match: match)

  defp normalize({path, match, target, priority}) when is_function(match, 1),
    do: validate_route(path: path, target: target, match: match, priority: priority)

  defp normalize(route), do: invalid_route(route)

  defp validate_route(route) do
    with {:ok, options} <- Spark.Options.validate(route, @route_schema),
         {:ok, path} <- validate_pattern(options[:path]) do
      {:ok,
       %{
         path: path,
         target: options[:target],
         priority: options[:priority],
         match: options[:match]
       }}
    else
      {:error, %Aikido.Error.RoutingError{}} = error -> error
      {:error, error} -> invalid_route(route, error)
    end
  end

  defp invalid_pattern(pattern) do
    {:error,
     Aikido.Error.routing_error("Invalid signal route pattern",
       details: %{pattern: pattern, reason: :invalid_pattern}
     )}
  end

  defp invalid_route(route, error \\ nil) do
    {:error, Aikido.Error.validation_error("Invalid signal route", route: route, error: error)}
  end
end
