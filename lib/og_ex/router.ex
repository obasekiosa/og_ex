defmodule OgEx.Router do
  @moduledoc """
  Installs the final path-image handler in a Phoenix router.

  Import this module and call `og_ex_routes/1` after all application routes:

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import OgEx.Router

        scope "/", MyAppWeb do
          pipe_through :browser
          get "/posts/:id", PostController, :show
        end

        og_ex_routes()
      end

  Use either this router integration or `plug OgEx, router: MyAppWeb.Router` in
  the endpoint. Do not install both.
  """

  @behaviour Plug

  @doc """
  Adds the final catch-all route used by path-mode card declarations.

  The macro must be called after application routes so explicitly owned routes
  take priority over OgEx image suffixes.
  """
  defmacro og_ex_routes(options \\ []) do
    quote bind_quoted: [options: options] do
      match :*, "/*og_ex_path", OgEx.Router, {__MODULE__, options}
    end
  end

  @doc false
  @impl Plug
  def init({router, options}), do: {router, options}

  @doc false
  @impl Plug
  def call(conn, {router, _options}), do: OgEx.Dispatcher.router(conn, router)
end
