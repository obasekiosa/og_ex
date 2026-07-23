defmodule OgEx.Controller do
  @moduledoc """
  Adds OgEx support to the standard Phoenix controller `render/3` call.

  Use it after the application's normal controller setup:

      use MyAppWeb, :controller
      use OgEx.Controller
  """

  @doc """
  Installs an OgEx-aware local `render/3` in the consuming controller.

  The generated function delegates to `OgEx.Controller.render/3`.
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

      Pass `og: CardModule` alongside the normal template assigns to enable the
      card for this render.
      """
      def render(conn, template, options) do
        OgEx.Controller.render(conn, template, options)
      end
    end
  end

  @doc """
  Dispatches a controller render to either Phoenix HTML or an OgEx image.

  Without an `:og` option this delegates directly to
  `Phoenix.Controller.render/3`. With a card, it builds the deterministic card
  configuration and selects the response using the signed request parameter.
  """
  def render(conn, template, options) when is_list(options) or is_map(options) do
    {card, page_assigns} = pop_card(options)

    if card do
      # Build the same deterministic config during the human page request and
      # the crawler's later image request. This is why the existing controller
      # action can serve both representations without a second route.
      config = OgEx.ConfigBuilder.build(conn, card, Map.new(page_assigns))

      if OgEx.Request.image_request?(conn) do
        # The reserved, signed query parameter selects the image response. The
        # normal Phoenix page template is never rendered on this branch.
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
