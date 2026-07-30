defmodule OgEx.Integration do
  @moduledoc false

  require Logger

  @doc """
  Warns when endpoint and router integrations are enabled together.
  """
  def warn_if_duplicate(router) when is_atom(router) do
    if router_enabled?(router) do
      Logger.warning("""
      OgEx endpoint and router integrations are both enabled for #{inspect(router)}. \
      Choose exactly one integration: either `plug OgEx, router: #{inspect(router)}` \
      in the endpoint or `og_ex_routes()` in the router. The endpoint plug will \
      receive requests first while both remain installed.
      """)
    end

    :ok
  end

  def warn_if_duplicate(_router), do: :ok

  @doc """
  Returns whether a compiled Phoenix router contains the OgEx catch-all route.
  """
  def router_enabled?(router) when is_atom(router) do
    Code.ensure_loaded?(router) and function_exported?(router, :__routes__, 0) and
      Enum.any?(router.__routes__(), &(&1.plug == OgEx.Router))
  end

  def router_enabled?(_router), do: false
end
