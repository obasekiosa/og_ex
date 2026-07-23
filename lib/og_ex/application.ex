defmodule OgEx.Application do
  @moduledoc false

  use Application

  @doc """
  Starts the OgEx supervision tree.

  The initial supervision tree owns the default ETS image cache.
  """
  @impl true
  def start(_type, _args) do
    # The default cache lives inside the OgEx supervision tree so applications
    # get a working local cache without adding their own child specification.
    #
    # Renderers are deliberately not processes. The Takumi renderer executes on
    # Rustler's dirty CPU scheduler and can therefore be called concurrently.
    children = [
      OgEx.Cache.ETS
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OgEx.Supervisor)
  end
end
