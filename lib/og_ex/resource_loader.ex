defmodule OgEx.ResourceLoader do
  @moduledoc """
  Behaviour for loading normalized image sources.

  Implement this behaviour to read images from authenticated storage, replace
  the HTTP policy, or provide fixtures. Configure the implementation with:

      config :og_ex, resource_loader: MyApp.OgResourceLoader

  A loader is responsible for returning verified metadata and encoded bytes.
  Custom implementations can delegate byte verification to
  `OgEx.ResourceLoader.Default.from_bytes/2`.
  """

  @doc """
  Loads one source and returns verified encoded bytes and metadata.

  Failures return `{:error, reason}`. Loaders should not raise for expected
  missing, policy, timeout, or validation failures.
  """
  @callback load(OgEx.Image.Source.t(), keyword()) ::
              {:ok, OgEx.Image.Resource.t()} | {:error, term()}
end
