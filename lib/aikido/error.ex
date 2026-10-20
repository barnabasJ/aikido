defmodule Aikido.Error do
  @moduledoc "Structured runtime validation and routing failures, with Splode aggregation."

  defmodule Invalid do
    @moduledoc false
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Routing do
    @moduledoc false
    use Splode.ErrorClass, class: :routing
  end

  defmodule Internal do
    @moduledoc false
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      use Splode.Error, class: :internal, fields: [:error, :details]
      def message(error), do: inspect(error.error)
    end
  end

  use Splode,
    error_classes: [invalid: Invalid, routing: Routing, internal: Internal],
    unknown_error: Internal.UnknownError

  defmodule ValidationError do
    @moduledoc """
    Error for validation failures.

    Covers invalid inputs, actions, and configurations.

    ## Fields

    - `message` - Human-readable error message
    - `kind` - Category: `:input`, `:action`, `:config`
    - `subject` - The invalid value (field name, action module, etc.)
    - `details` - Additional context
    """
    use Splode.Error,
      class: :invalid,
      fields: [:message, :kind, :subject, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            kind: :input | :action | :config | nil,
            subject: any(),
            details: map()
          }

    @impl true
    def exception(opts) do
      opts = if is_map(opts), do: Map.to_list(opts), else: opts

      opts
      |> Keyword.put_new(:message, "Validation failed")
      |> Keyword.put_new(:details, %{})
      |> super()
    end
  end

  defmodule RoutingError do
    @moduledoc """
    Error for signal routing and dispatch failures.

    ## Fields

    - `message` - Human-readable error message
    - `target` - The intended routing target
    - `details` - Additional context
    """
    use Splode.Error,
      class: :routing,
      fields: [:message, :target, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            target: any(),
            details: map()
          }

    @impl true
    def exception(opts) do
      opts = if is_map(opts), do: Map.to_list(opts), else: opts

      opts
      |> Keyword.put_new(:message, "Routing failed")
      |> Keyword.put_new(:details, %{})
      |> super()
    end
  end

  @spec validation_error(String.t(), keyword() | map()) :: ValidationError.t()
  def validation_error(message, opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    # Infer kind and subject from convenience keys
    {kind, subject} =
      cond do
        opts[:action] -> {:action, opts[:action]}
        opts[:field] -> {:input, opts[:field]}
        true -> {opts[:kind], opts[:subject]}
      end

    ValidationError.exception(
      message: message,
      kind: kind,
      subject: subject,
      details: merge_extra_details(opts, [:kind, :subject, :action, :field])
    )
  end

  @spec routing_error(String.t(), keyword() | map()) :: RoutingError.t()
  def routing_error(message, opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    RoutingError.exception(
      message: message,
      target: Keyword.get(opts, :target),
      details: Keyword.get(opts, :details, %{})
    )
  end

  defp merge_extra_details(opts, reserved_keys) do
    explicit_details =
      case Keyword.get(opts, :details, %{}) do
        details when is_map(details) -> details
        _ -> %{}
      end

    extra_details =
      opts
      |> Keyword.drop([:details | reserved_keys])
      |> Enum.into(%{})

    Map.merge(extra_details, explicit_details)
  end

  @doc "Whether an execution failure should be retried; native Ash input errors are terminal."
  @spec retryable?(term()) :: boolean()
  def retryable?({:error, reason, _effects}), do: retryable?(reason)
  def retryable?({:error, reason}), do: retryable?(reason)
  def retryable?(%ValidationError{}), do: false
  def retryable?(%{class: class}) when class in [:invalid, :forbidden], do: false
  def retryable?(%Internal.UnknownError{details: details}), do: retryable_hint(details, true)

  def retryable?(%{retryable?: value}) when is_boolean(value), do: value
  def retryable?(%{retryable: value}) when is_boolean(value), do: value

  def retryable?(%{type: type} = error) when is_atom(type) do
    retryable_hint(Map.get(error, :details, error), default_retryable?(type))
  end

  def retryable?(%{code: type} = error) when is_atom(type) do
    retryable_hint(Map.get(error, :details, error), default_retryable?(type))
  end

  def retryable?(%{} = map) do
    retryable_hint(map, true)
  end

  def retryable?(reason) when is_atom(reason), do: default_retryable?(reason)
  def retryable?(_reason), do: true

  defp default_retryable?(type) when type in [:validation_error, :configuration_error], do: false
  defp default_retryable?(_type), do: true

  defp retryable_hint(term, default) do
    case extract_retry_hint(term) do
      nil -> default
      value -> value != false
    end
  end

  defp extract_retry_hint(%{details: details}) do
    case extract_retry_value(details) do
      nil -> details |> extract_nested_reason() |> extract_retry_hint()
      value -> value
    end
  end

  defp extract_retry_hint(%{} = map) do
    case extract_retry_value(map) do
      nil -> map |> extract_nested_reason() |> extract_retry_hint()
      value -> value
    end
  end

  defp extract_retry_hint(_), do: nil

  defp extract_nested_reason(%{} = map) do
    Map.get(map, :reason) || Map.get(map, "reason")
  end

  defp extract_nested_reason(_), do: nil

  defp extract_retry_value(%{} = map) do
    cond do
      Map.has_key?(map, :retry) -> Map.get(map, :retry)
      Map.has_key?(map, "retry") -> Map.get(map, "retry")
      true -> nil
    end
  end

  defp extract_retry_value(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword), do: Keyword.get(keyword, :retry), else: nil
  end

  defp extract_retry_value(_), do: nil
end
