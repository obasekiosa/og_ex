defmodule OgEx.ResourceLoader do
  @moduledoc """
  Loads and verifies image resources used inside generated cards.
  """

  @doc """
  Loads one normalized source and returns verified image bytes and metadata.
  """
  @callback load(OgEx.Image.Source.t(), keyword()) ::
              {:ok, OgEx.Image.Resource.t()} | {:error, term()}
end
