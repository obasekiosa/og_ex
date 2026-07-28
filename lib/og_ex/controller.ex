defmodule OgEx.Controller do
  @moduledoc """
  Adds OgEx declarations to a Phoenix controller's `render/3` call.

  Use it after the application's normal controller setup:

      use MyAppWeb, :controller
      use OgEx.Controller

  A render may select a generated card:

      render(conn, :show, post: post, og: MyAppWeb.PostOgCard)

  Or an existing image:

      render(conn, :about,
        og: [title: "About Acme", image: "/images/about-og.png"]
      )

  Calls without `:og` keep normal Phoenix behavior.

  The README contains complete controller actions for generated cards,
  embedded image resources, and direct existing images.
  """

  @doc """
  Installs an OgEx-aware local `render/3` in the consuming controller.

  The generated function delegates to `render/3` in this module. Install the
  integration after the application's normal controller setup so OgEx can
  replace Phoenix's imported `render/3`.
  """
  defmacro __using__(_options) do
    quote do
      # Phoenix controller modules normally import `render/3`. Explicitly
      # exclude that import before defining the OgEx-aware local function so
      # consuming controllers compile without an import conflict.
      import Phoenix.Controller, except: [render: 3]

      # Calls without `:og` are delegated unchanged, so installing OgEx does
      # not alter ordinary controller renders.
      @doc """
      Renders a Phoenix page or its OgEx image representation.

      `:og` may be an `OgEx.Card` module or direct image metadata containing
      `:title` and `:image`.
      """
      def render(conn, template, options) do
        OgEx.Controller.render(conn, template, options)
      end
    end
  end

  @doc """
  Dispatches a controller render to either Phoenix HTML or an OgEx image.

  Without `:og`, this delegates to `Phoenix.Controller.render/3`.

  With a card module, normal requests register generated-image metadata and
  signed requests return the card image. With direct metadata, public and
  external sources are emitted as existing URLs while private sources use a
  signed response.

  This function expects controller render options as a keyword list or map.
  """
  def render(conn, template, options) when is_list(options) or is_map(options) do
    {declaration, page_assigns} = pop_card(options)

    if declaration do
      # Build the same deterministic config during the human page request and
      # the crawler's later image request. This is why the existing controller
      # action can serve both representations without a second route.
      config = OgEx.ConfigBuilder.build(conn, declaration, Map.new(page_assigns))

      if OgEx.Request.image_request?(conn) do
        # The reserved compact signature selects the image response. Query
        # parameters are fetched lazily here, and the normal Phoenix page
        # template is never rendered on this branch.
        OgEx.ImageResponse.send(conn, config)
      else
        # Register metadata before Phoenix renders and sends the response. The
        # callback runs from `send_resp/3`, after the root layout has produced
        # the complete HTML document.
        conn
        |> OgEx.Head.put_config(config)
        |> Phoenix.Controller.render(template, page_assigns)
      end
    else
      # Preserve Phoenix semantics for every render that does not opt into OgEx.
      Phoenix.Controller.render(conn, template, page_assigns)
    end
  end

  # Removes the optional card module from keyword-list assigns while preserving
  # every ordinary Phoenix template assign.
  defp pop_card(options) when is_list(options), do: Keyword.pop(options, :og)

  # Removes the optional card module from map assigns while preserving the map
  # shape expected by Phoenix.Controller.render/3.
  defp pop_card(options) when is_map(options) do
    {Map.get(options, :og), Map.delete(options, :og)}
  end
end
