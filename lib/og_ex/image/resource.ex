defmodule OgEx.Image.Resource do
  @moduledoc """
  Verified image bytes returned by an `OgEx.ResourceLoader`.
  """

  @enforce_keys [:source, :bytes, :content_type, :format, :width, :height, :fingerprint]
  defstruct @enforce_keys ++ [:etag, :last_modified]

  @type t :: %__MODULE__{
          source: OgEx.Image.Source.t(),
          bytes: binary(),
          content_type: String.t(),
          format: atom(),
          width: pos_integer(),
          height: pos_integer(),
          fingerprint: String.t(),
          etag: String.t() | nil,
          last_modified: String.t() | nil
        }
end
