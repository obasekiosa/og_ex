defmodule OgEx.Controller do
  @moduledoc """
  Adds action-level social-card declarations to a Phoenix controller.

  Use it after the application's normal controller setup:

      use MyAppWeb, :controller
      use OgEx.Controller

  Declare a generated card once:

      og_card :show, MyAppWeb.PostOgCard

  The card's `load/2` callback runs only for signed image requests. An explicit
  controller loader can override it:

      og_card :show, MyAppWeb.PostOgCard,
        load: &load_post_card/2,
        image_route: :query

  Existing `render(..., og: Card)` and direct-image declarations remain
  supported for compatibility.

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
      import OgEx.Controller, only: [og_card: 2, og_card: 3]

      Module.register_attribute(__MODULE__, :og_ex_declarations, accumulate: true)
      @before_compile OgEx.Controller

      # Query-mode image requests are intercepted before Phoenix invokes the
      # controller action. Controllers without a matching declaration pass
      # through unchanged.
      plug :__og_ex_before_action__

      # Calls without `:og` are delegated unchanged, so installing OgEx does
      # not alter ordinary controller renders.
      @doc """
      Renders a Phoenix page or its OgEx image representation.

      `:og` may be an `OgEx.Card` module or direct image metadata containing
      `:title` and `:image`.
      """
      def render(conn, template, options) do
        OgEx.Controller.render(conn, template, options, __MODULE__)
      end

      @doc false
      def __og_ex_before_action__(conn, _options) do
        OgEx.Controller.before_action(conn, __MODULE__)
      end
    end
  end

  @doc """
  Declares the card used by one controller action.

  The card's optional `load/2` callback supplies assigns for standalone image
  requests. Pass `load: &function/2` to override card-local loading.
  """
  defmacro og_card(action, card, options \\ []) do
    action = Macro.expand(action, __CALLER__)
    card = Macro.expand(card, __CALLER__)

    unless is_atom(action) do
      raise ArgumentError,
            "og_card action must be a literal atom, got: #{Macro.to_string(action)}"
    end

    unless is_atom(card) do
      raise ArgumentError, "og_card card must expand to a module, got: #{Macro.to_string(card)}"
    end

    unless is_list(options) do
      raise ArgumentError, "og_card options must be a literal keyword list"
    end

    allowed_options = [:load, :image_route]
    unknown_options = Keyword.keys(options) -- allowed_options

    if unknown_options != [] do
      raise ArgumentError, "unknown og_card options: #{inspect(unknown_options)}"
    end

    image_route = Keyword.get(options, :image_route, :default)
    validate_image_route!(image_route)

    declaration = %{
      action: action,
      card: card,
      image_route: image_route,
      loader: Keyword.get(options, :load)
    }

    quote do
      @og_ex_declarations unquote(Macro.escape(declaration))
    end
  end

  @doc false
  defmacro __before_compile__(environment) do
    declarations =
      environment.module
      |> Module.get_attribute(:og_ex_declarations)
      |> Enum.reverse()

    actions = Enum.map(declarations, & &1.action)
    duplicate_actions = actions -- Enum.uniq(actions)

    if duplicate_actions != [] do
      raise CompileError,
        file: environment.file,
        line: environment.line,
        description:
          "duplicate og_card declarations for actions: #{inspect(Enum.uniq(duplicate_actions))}"
    end

    declaration_clauses =
      Enum.map(declarations, fn declaration ->
        public_declaration = Map.delete(declaration, :loader)

        quote do
          def __og_ex_declaration__(unquote(declaration.action)) do
            unquote(Macro.escape(public_declaration))
          end
        end
      end)

    loader_clauses =
      Enum.map(declarations, fn declaration ->
        loader_call =
          case declaration.loader do
            nil ->
              quote do
                if Code.ensure_loaded?(unquote(declaration.card)) and
                     function_exported?(unquote(declaration.card), :load, 2) do
                  unquote(declaration.card).load(conn, params)
                else
                  {:error, :missing_loader}
                end
              end

            {:&, _metadata, [{:/, _slash_metadata, [{name, _, context}, 2]}]}
            when is_atom(name) and (is_atom(context) or is_nil(context)) ->
              quote do
                unquote(name)(conn, params)
              end

            loader ->
              quote do
                loader = unquote(loader)
                loader.(conn, params)
              end
          end

        quote do
          def __og_ex_load__(unquote(declaration.action), conn, params) do
            unquote(loader_call)
          end
        end
      end)

    quote do
      unquote_splicing(declaration_clauses)
      def __og_ex_declaration__(_action), do: nil

      unquote_splicing(loader_clauses)
      def __og_ex_load__(_action, _conn, _params), do: {:error, :unknown_declaration}

      @doc false
      def __og_ex_declarations__ do
        unquote(Macro.escape(Enum.map(declarations, &Map.delete(&1, :loader))))
      end
    end
  end

  @doc """
  Dispatches a controller render to Phoenix HTML or a legacy OgEx image.

  Without `:og`, this delegates to `Phoenix.Controller.render/3`.

  A declared action automatically selects its card when no explicit `:og`
  option exists. Query image requests for declared actions are intercepted by
  the controller plug before this function or the action executes.

  This function expects controller render options as a keyword list or map.
  """
  def render(conn, template, options, controller)
      when (is_list(options) or is_map(options)) and is_atom(controller) do
    {explicit_declaration, page_assigns} = pop_card(options)
    controller_declaration = declaration(controller, action(conn))
    selected_declaration = explicit_declaration || card(controller_declaration)

    if selected_declaration do
      # Build the same deterministic config during the human page request and
      # the crawler's later image request. This is why the existing controller
      # action can serve both representations without a second route.
      config =
        OgEx.ConfigBuilder.build(
          conn,
          selected_declaration,
          Map.new(page_assigns),
          config_builder_options(explicit_declaration, controller_declaration)
        )

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

  @doc """
  Intercepts declaration-based query image requests before controller actions.
  """
  def before_action(conn, controller) do
    action = action(conn)
    declaration = declaration(controller, action)

    if (OgEx.Request.image_request?(conn) and declaration) &&
         route_strategy(declaration) == :query do
      dispatch_image(conn, controller, action)
    else
      conn
    end
  end

  @doc false
  def dispatch_image(conn, controller, action) do
    declaration = declaration(controller, action)
    params = OgEx.Request.application_params(conn)

    conn =
      if OgEx.Request.origin(conn) do
        conn
      else
        OgEx.Request.put_origin(conn, controller, action, :image, params)
      end

    result =
      try do
        controller.__og_ex_load__(action, conn, params)
      catch
        kind, reason -> {:error, {:loader_exception, kind, reason}}
      end

    case result do
      {:ok, assigns} when is_map(assigns) ->
        config =
          OgEx.ConfigBuilder.build(conn, declaration.card, assigns,
            image_route: route_strategy(declaration)
          )

        conn
        |> OgEx.ImageResponse.send(config)
        |> Plug.Conn.halt()

      {:error, reason} ->
        send_loader_error(conn, controller, action, reason)

      other ->
        send_loader_error(conn, controller, action, {:invalid_loader_result, other})
    end
  end

  # Backward-compatible entry point retained for direct callers.
  @doc false
  def render(conn, template, options) when is_list(options) or is_map(options) do
    render(conn, template, options, conn.private[:phoenix_controller])
  end

  # Removes the optional card module from keyword-list assigns while preserving
  # every ordinary Phoenix template assign.
  defp pop_card(options) when is_list(options), do: Keyword.pop(options, :og)

  # Removes the optional card module from map assigns while preserving the map
  # shape expected by Phoenix.Controller.render/3.
  defp pop_card(options) when is_map(options) do
    {Map.get(options, :og), Map.delete(options, :og)}
  end

  defp declaration(nil, _action), do: nil
  defp declaration(_controller, nil), do: nil

  defp declaration(controller, action) do
    if Code.ensure_loaded?(controller) and
         function_exported?(controller, :__og_ex_declaration__, 1) do
      controller.__og_ex_declaration__(action)
    end
  end

  defp action(conn), do: conn.private[:phoenix_action]

  defp card(%{card: card}), do: card
  defp card(_declaration), do: nil

  defp config_builder_options(explicit_declaration, _controller_declaration)
       when not is_nil(explicit_declaration),
       do: []

  defp config_builder_options(nil, declaration),
    do: [image_route: route_strategy(declaration)]

  @doc false
  def route_strategy(%{image_route: :default}) do
    Application.get_env(:og_ex, :image_route, :path)
  end

  def route_strategy(%{image_route: strategy}) when strategy in [:path, :query], do: strategy

  defp send_loader_error(conn, controller, action, reason) do
    status = if reason in [:not_found, :forbidden], do: :not_found, else: :service_unavailable

    :telemetry.execute(
      [:og_ex, :loader, :exception],
      %{system_time: System.system_time()},
      %{controller: controller, action: action, reason: reason}
    )

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(status, "")
    |> Plug.Conn.halt()
  end

  defp validate_image_route!(:default), do: :ok
  defp validate_image_route!(:path), do: :ok
  defp validate_image_route!(:query), do: :ok

  defp validate_image_route!(other) do
    raise ArgumentError,
          "og_card :image_route must be :path or :query, got: #{inspect(other)}"
  end
end
