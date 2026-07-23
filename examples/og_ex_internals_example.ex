# ILLUSTRATIVE OGEX LIBRARY INTERNALS
#
# Application developers do not write or call these modules directly. This
# example intentionally omits production details such as telemetry, request
# coalescing, remote-asset policies, cache adapters, and exhaustive errors.

defmodule OgEx.Controller do
  defmacro __using__(_options) do
    quote do
      import Phoenix.Controller, except: [render: 3]
      import OgEx.Controller, only: [render: 3]
    end
  end

  # This has the same shape as Phoenix's render/3, with one additional `:og`
  # option identifying the card.
  def render(conn, page_template, options) do
    {card, page_assigns} = Keyword.pop!(options, :og)
    assigns = Map.new(page_assigns)
    config = OgEx.build_config(conn, card, assigns)

    if OgEx.Request.image_request?(conn) do
      OgEx.ImageResponse.send(conn, config)
    else
      conn
      |> OgEx.Head.put_config(config)
      |> Phoenix.Controller.render(page_template, page_assigns)
    end
  end
end
defmodule OgEx.Request do
  @parameter "__og_ex"

  def image_request?(%Plug.Conn{query_params: %{@parameter => _token}}),
    do: true

  def image_request?(_conn), do: false

  def token(%Plug.Conn{query_params: %{@parameter => token}}), do: token
end

defmodule OgEx do
  use Supervisor

  @token_salt "og-ex-image"

  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl Supervisor
  def init(_options) do
    children = [
      # ChromicPDF is itself a supervision tree and controls the number of
      # concurrent browser sessions.
      ChromicPDF,
      OgEx.Cache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Called during both the page request and the later crawler image request.
  def build_config(conn, card, assigns) do
    metadata = card.metadata(assigns)
    version = version(card, assigns)

    signed_token =
      Phoenix.Token.sign(
        conn,
        @token_salt,
        {card, version}
      )

    %OgEx.Config{
      card: card,
      assigns: assigns,
      metadata: metadata,
      width: card.__og_ex__(:width),
      height: card.__og_ex__(:height),
      version: version,
      image_url: image_url(conn, signed_token)
    }
  end

  # A real implementation should let the card provide a stable version callback
  # and should reject unstable values such as PIDs or unloaded associations.
  def version(card, assigns) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({card, assigns})
    )
    |> Base.url_encode64(padding: false)
  end

  def verify_image_request(conn, %OgEx.Config{} = config) do
    with token when is_binary(token) <- OgEx.Request.token(conn),
         {:ok, {card, version}} <-
           Phoenix.Token.verify(conn, @token_salt, token, max_age: 31_536_000),
         true <- card == config.card,
         true <- version == config.version do
      :ok
    else
      _ -> {:error, :invalid_image_token}
    end
  end

  defp image_url(conn, signed_token) do
    conn
    |> Phoenix.Controller.current_url(%{"__og_ex" => signed_token})
  end
end

defmodule OgEx.Config do
  @enforce_keys [
    :card,
    :assigns,
    :metadata,
    :width,
    :height,
    :version,
    :image_url
  ]

  defstruct @enforce_keys
end

defmodule OgEx.ImageResponse do
  import Plug.Conn

  def send(conn, config) do
    with :ok <- OgEx.verify_image_request(conn, config),
         {:ok, png} <- cached_or_render(config) do
      conn
      |> put_resp_content_type("image/png")
      |> put_resp_header(
        "cache-control",
        "public, max-age=31536000, immutable"
      )
      |> put_resp_header("etag", ~s("#{config.version}"))
      |> send_resp(:ok, png)
    else
      {:error, :invalid_image_token} ->
        send_resp(conn, :not_found, "")

      {:error, _render_error} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(:service_unavailable, "")
    end
  end

  defp cached_or_render(config) do
    case OgEx.Cache.fetch(config.version) do
      {:ok, png} ->
        {:ok, png}

      :error ->
        with {:ok, html} <- OgEx.HTML.render(config),
             {:ok, png} <-
               OgEx.Renderer.Chromium.screenshot(
                 html,
                 config.width,
                 config.height
               ) do
          :ok = OgEx.Cache.put(config.version, png)
          {:ok, png}
        end
    end
  end
end

defmodule OgEx.HTML do
  def render(config) do
    body =
      config.card.render(config.assigns)
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    html = """
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
    """

    {:ok, html}
  rescue
    error -> {:error, {:invalid_card_html, error}}
  end
end

defmodule OgEx.Renderer.Chromium do
  # ChromicPDF.capture_screenshot/2 returns a base64-encoded image when no
  # output file/callback is supplied.
  def screenshot(html, width, height) do
    options = [
      capture_screenshot: %{
        format: "png",
        captureBeyondViewport: true,
        clip: %{
          x: 0,
          y: 0,
          width: width,
          height: height,
          scale: 1
        }
      },
      telemetry_metadata: %{renderer: :og_ex}
    ]

    with {:ok, encoded_png} <-
           ChromicPDF.capture_screenshot({:html, html}, options),
         {:ok, png} <- Base.decode64(encoded_png) do
      {:ok, png}
    else
      {:error, reason} -> {:error, {:chromium, reason}}
      :error -> {:error, :invalid_chromium_output}
    end
  end
end

defmodule OgEx.Head do
  # The endpoint-level OgEx plug registers this response callback. Kept as a
  # separate function here to show the normal-page side of the lifecycle.
  def put_config(conn, config) do
    conn
    |> Plug.Conn.assign(:og_ex, config)
    |> Plug.Conn.register_before_send(&inject_meta/1)
  end

  defp inject_meta(%Plug.Conn{resp_body: body} = conn)
       when is_binary(body) do
    tags = OgEx.Meta.to_html(conn.assigns.og_ex)
    updated_body = String.replace(body, "</head>", tags <> "\n</head>")
    %{conn | resp_body: updated_body}
  end

  defp inject_meta(conn), do: conn
end

defmodule OgEx.Meta do
  # Production code should construct tags with Phoenix.HTML.Tag so every value
  # is escaped correctly. This function is abbreviated to keep focus on the
  # image-response pipeline.
  def to_html(config) do
    safe_title =
      config.metadata.title
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.Safe.to_iodata()

    safe_image_url =
      config.image_url
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.Safe.to_iodata()

    IO.iodata_to_binary([
      ~s(<meta property="og:title" content="),
      safe_title,
      ~s(">\n<meta property="og:image" content="),
      safe_image_url,
      ~s(">\n<meta name="twitter:card" content="summary_large_image">)
    ])
  end
end

defmodule OgEx.Cache do
  use GenServer

  @table __MODULE__

  def start_link(_options) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, png}] -> {:ok, png}
      [] -> :error
    end
  end

  def put(key, png) do
    true = :ets.insert(@table, {key, png})
    :ok
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    {:ok, %{}}
  end
end
