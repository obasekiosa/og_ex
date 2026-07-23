# APPLICATION CODE
#
# `OgEx` is the Elixir module name. The Hex package and OTP application would
# be named `og_ex`.
#
# The application would depend on OgEx; OgEx would bring ChromicPDF as its
# default HTML/CSS renderer:
#
#   {:og_ex, "~> 0.1"}
#
# Production also needs a Chrome or Chromium executable. Node.js, Puppeteer,
# and Ghostscript are not required for PNG screenshots.

defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyAppWeb.Telemetry,
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},

      # Starts OgEx's cache and supervised ChromicPDF browser pool.
      OgEx,

      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: MyApp.Supervisor
    )
  end
end

defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # One application-wide installation. This does not add a public route.
  # It recognizes OgEx's signed query parameter on any existing page route.
  plug OgEx

  plug MyAppWeb.Router
end

defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", MyAppWeb do
    pipe_through :browser

    # There is no user-defined image route.
    get "/posts/:id", PostController, :show
  end
end

defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller
  use OgEx.Controller

  alias MyApp.Blog
  alias MyAppWeb.PostOgCard

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    # This replaces the normal Phoenix `render/3` call.
    #
    # For a normal request, it renders `show.html.heex` and injects metadata
    # into <head>. For OgEx's internal image request, it renders PostOgCard as
    # a PNG and skips the page template.
    render(conn, :show, post: post, og: PostOgCard)
  end
end

defmodule MyAppWeb.PostOgCard do
  use OgEx.Card,
    width: 1200,
    height: 630,
    format: :png

  # Metadata and visual presentation live together. The controller does not
  # repeat any of these values.
  def metadata(%{post: post}) do
    %{
      title: post.title,
      description: post.summary,
      type: "article",
      image_alt: "Social card for #{post.title}",
      twitter_card: "summary_large_image"
    }
  end

  # This is HEEx/HTML, not a new layout DSL. OgEx renders it with an HTML/CSS
  # backend such as headless Chromium.
  def render(assigns) do
    ~H"""
    <main class="card">
      <p class="site">EXAMPLE.COM</p>

      <section>
        <h1>{@post.title}</h1>
        <p class="author">By {@post.author.name}</p>
      </section>
    </main>

    <style>
      * {
        box-sizing: border-box;
      }

      body {
        margin: 0;
        font-family: Inter, sans-serif;
      }

      .card {
        width: 1200px;
        height: 630px;
        padding: 72px;
        display: flex;
        flex-direction: column;
        justify-content: space-between;
        color: white;
        background:
          radial-gradient(circle at top right, #4f46e5, transparent 45%),
          #0f172a;
      }

      .site {
        margin: 0;
        font-size: 26px;
        font-weight: 700;
        letter-spacing: 0.16em;
      }

      h1 {
        max-width: 1000px;
        margin: 0 0 24px;
        font-size: 72px;
        line-height: 1.05;
      }

      .author {
        margin: 0;
        color: #c7d2fe;
        font-size: 30px;
      }
    </style>
    """
  end
end

defmodule MyAppWeb.PostHTML do
  use MyAppWeb, :html

  # This would normally be `post_html/show.html.heex`.
  attr :post, :map, required: true

  def show(assigns) do
    ~H"""
    <article>
      <header>
        <p>{@post.author.name}</p>
        <h1>{@post.title}</h1>
      </header>

      <p>{@post.summary}</p>
      <div>{@post.body}</div>
    </article>
    """
  end
end

defmodule MyAppWeb.Layouts do
  use MyAppWeb, :html

  # No `<OgEx.meta>` call is required. On normal HTML responses, the OgEx plug
  # inserts the generated tags immediately before `</head>`.
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <.live_title default="Example">{assigns[:page_title]}</.live_title>
      </head>

      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

# WHAT OGEX WIRES UP INTERNALLY
#
# The application developer does not write the code below. It illustrates the
# contract implemented by `use OgEx.Controller` and `plug OgEx`.
#
# Normal page request:
#
#   GET /posts/42
#
# `render(conn, :show, post: post, og: PostOgCard)`:
#
#   1. calls PostOgCard.metadata(%{post: post});
#   2. creates a signed, versioned image URL from the current page URL;
#   3. renders the ordinary Phoenix template;
#   4. inserts OG and Twitter/X tags before `</head>`.
#
# The generated metadata points to a URL such as:
#
#   https://example.com/posts/42?__og_ex=SIGNED_VERSION
#
# Image request:
#
#   GET /posts/42?__og_ex=SIGNED_VERSION
#
# The same router and controller action run, so `post` is loaded normally.
# When the action reaches the OgEx-aware `render/3`, OgEx:
#
#   1. verifies the signed parameter;
#   2. calls PostOgCard.render(%{post: post});
#   3. converts the safe HEEx result to an HTML document;
#   4. asks supervised headless Chromium to capture that document;
#   5. decodes Chromium's base64 PNG result;
#   6. stores the PNG under a content-derived cache key;
#   7. returns `image/png` with ETag and immutable cache headers.
#
# This is why no generated Phoenix route, image controller, loader callback, or
# duplicate query logic is required in application code.
#
# See `og_ex_internals_example.ex` for an illustrative implementation of this
# dispatch and Chromium screenshot pipeline.
