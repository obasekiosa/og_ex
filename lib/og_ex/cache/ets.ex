defmodule OgEx.Cache.ETS do
  @moduledoc """
  In-memory cache used by default.
  """

  @behaviour OgEx.Cache
  use GenServer

  @table __MODULE__

  @doc """
  Starts the process that owns the named ETS image table.
  """
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc """
  Retrieves an image directly from ETS, returning `:error` when absent.
  """
  @impl OgEx.Cache
  def fetch(key) do
    # ETS reads bypass the GenServer mailbox, allowing concurrent crawler
    # requests to hit the cache without serializing through one process.
    case :ets.lookup(@table, key) do
      [{^key, image}] -> {:ok, image}
      [] -> :error
    end
  end

  @doc """
  Inserts or replaces an encoded image in the ETS cache.
  """
  @impl OgEx.Cache
  def put(key, image) do
    # The rendered binary is immutable, so replacing an identical key is safe.
    true = :ets.insert(@table, {key, image})
    :ok
  end

  @doc """
  Creates the concurrent-read ETS table owned by the cache process.

  This is the `GenServer` initialization callback.
  """
  @impl GenServer
  def init(_options) do
    # This process owns the table; OTP automatically removes it if the cache
    # process terminates and recreates it when the supervisor restarts the child.
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    {:ok, %{}}
  end
end
