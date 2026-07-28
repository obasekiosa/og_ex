defmodule OgEx.Image.Source do
  @moduledoc """
  Normalized description of an image source.

  Sources are produced by `OgEx.Image.normalize/2`; applications normally pass
  strings or `{:private, path}` tuples rather than constructing this struct.

  `:reference` retains the source identity used by metadata or generated HTML.
  `:path` is populated only after a local source has been constrained to its
  trusted root. The remaining optional fields allow loaders to attach verified
  metadata without changing the source type.
  """

  @type source_type :: :public | :private | :remote | :data

  @enforce_keys [:type, :reference]
  defstruct [
    :type,
    :reference,
    :path,
    :content_type,
    :format,
    :width,
    :height,
    :fingerprint,
    :bytes
  ]

  @type t :: %__MODULE__{
          type: source_type(),
          reference: String.t(),
          path: String.t() | nil,
          content_type: String.t() | nil,
          format: atom() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          fingerprint: String.t() | nil,
          bytes: binary() | nil
        }
end
