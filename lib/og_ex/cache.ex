defmodule OgEx.Cache do
  @moduledoc """
  Behaviour for rendered image caches.
  """

  @doc """
  Retrieves an encoded image for a renderer cache key.
  """
  @callback fetch(key :: term()) :: {:ok, binary()} | :error

  @doc """
  Stores an encoded image under a renderer cache key.
  """
  @callback put(key :: term(), image :: binary()) :: :ok
end
