defmodule OgEx.Cache do
  @moduledoc """
  Behaviour for final generated-image caches.

  Configure an implementation with `config :og_ex, cache: MyCache`. Cache keys
  are internal terms and may change between OgEx versions; implementations
  should treat them as opaque.
  """

  @doc """
  Retrieves an encoded image for a renderer cache key.

  Returns `{:ok, image}` when the key exists and `:error` when it is absent,
  following the convention established by `Map.fetch/2`.
  """
  @callback fetch(key :: term()) :: {:ok, binary()} | :error

  @doc """
  Stores a complete encoded image under a renderer cache key.

  Failed or partial renders are never passed to this callback.
  """
  @callback put(key :: term(), image :: binary()) :: :ok
end
