defmodule OgEx.Config do
  @moduledoc false

  @enforce_keys [
    :card,
    :assigns,
    :metadata,
    :width,
    :height,
    :format,
    :version,
    :image_url
  ]

  defstruct @enforce_keys
end
