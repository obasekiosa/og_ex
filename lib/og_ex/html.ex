defmodule OgEx.HTML do
  @moduledoc false

  @doc """
  Converts a card component into a complete HTML document.

  HEEx safe data is preserved, and a package-level viewport reset is added
  before the document crosses into the native renderer.
  """
  def render(%OgEx.Config{} = config) do
    # HEEx returns a safe-data structure rather than a plain string. Converting
    # through the Phoenix.HTML.Safe protocol preserves HEEx escaping guarantees
    # before the fragment crosses the NIF boundary.
    body =
      config.card.render(config.assigns)
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    # Takumi accepts an HTML fragment, but a complete document gives us a
    # predictable viewport reset and a place for package-level styles.
    {:ok,
     """
     <!doctype html>
     <html>
       <head>
         <meta charset="utf-8">
         <style>
           html, body {
             width: #{config.width}px;
             height: #{config.height}px;
             margin: 0;
             overflow: hidden;
           }
         </style>
       </head>
       <body>#{body}</body>
     </html>
     """}
  rescue
    # Card component failures become ordinary renderer errors. They should not
    # crash the endpoint process or leak the original assigns into logs.
    error -> {:error, {:invalid_card_html, error}}
  end
end
