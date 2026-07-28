defmodule OgEx.Image.Resource do
  @moduledoc """
  Verified image bytes returned by an `OgEx.ResourceLoader`.

  A resource contains encoded bytes, detected format and content type,
  intrinsic dimensions, and a SHA-256 content fingerprint. Remote loaders may
  also retain ETag and Last-Modified values for conditional revalidation.

  Applications normally receive this struct only when implementing a resource
  loader or inspecting loader results.
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
