# Shared setup for OgEx benchmarks.
#
# Run from the repository root:
#
#   mix run bench/render_bench.exs
#   mix run bench/lifecycle_bench.exs
#
# The modules below mirror test/support so benchmarks exercise the same
# macros, router integration, and dispatch paths as the lifecycle tests while
# using realistic card layouts.

font =
  Enum.find(
    [
      "/usr/share/fonts/opentype/urw-base35/NimbusSans-Regular.otf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
      "/Library/Fonts/Arial.ttf"
    ],
    &File.regular?/1
  )

Application.put_env(:og_ex, :fonts, List.wrap(font))

{:ok, _} = Application.ensure_all_started(:og_ex)

# Phoenix logs one debug line per routed request; silence it so benchmark
# output stays readable and timing is not polluted by log formatting.
Logger.configure(level: :info)

defmodule OgEx.Bench.WideCard do
  @moduledoc false

  # Realistic wide article card modeled on the README example: gradient
  # background, eyebrow, long title, and author line at 1200x630.
  use OgEx.Card, width: 1200, height: 630, format: :png

  @impl OgEx.Card
  def metadata(%{title: title}) do
    %{
      title: title,
      description: "Benchmark social card for #{title}",
      type: "article",
      image_alt: "Social card for #{title}",
      twitter_card: "summary_large_image"
    }
  end

  # `:rev` lets the cold-cache benchmark force a unique version per request
  # while warm-cache requests share one stable version.
  @impl OgEx.Card
  def version(%{title: title} = assigns), do: {:bench_wide, Map.get(assigns, :rev, 0), title}

  @impl OgEx.Card
  def load(_conn, %{"id" => id}), do: {:ok, %{title: "Loaded post #{id}", rev: bench_rev(id)}}

  defp bench_rev(id) do
    case Integer.parse(id) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main class="card">
      <p class="site">ACME ENGINEERING</p>

      <section>
        <h1>{@title}</h1>
        <p class="author">By Ada Lovelace</p>
      </section>
    </main>

    <style>
      * {
        box-sizing: border-box;
      }

      .card {
        width: 100%;
        height: 100%;
        padding: 72px;
        display: flex;
        flex-direction: column;
        justify-content: space-between;
        color: white;
        background:
          radial-gradient(circle at top right, #4f46e5, transparent 45%),
          #0f172a;
        font-family: sans-serif;
      }

      .site {
        margin: 0;
        color: #a5b4fc;
        font-size: 24px;
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

defmodule OgEx.Bench.SquareCard do
  @moduledoc false

  use OgEx.Card, width: 600, height: 600, format: :png

  @impl OgEx.Card
  def metadata(%{title: title}), do: %{title: title, twitter_card: "summary"}

  @impl OgEx.Card
  def version(assigns), do: {:bench_square, Map.get(assigns, :rev, 0)}

  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main class="card">
      <section>
        <h1>{@title}</h1>
      </section>
    </main>

    <style>
      .card {
        width: 100%;
        height: 100%;
        padding: 48px;
        display: flex;
        align-items: center;
        justify-content: center;
        text-align: center;
        color: #f8fafc;
        background: #111827;
        font-family: sans-serif;
      }

      h1 {
        margin: 0;
        font-size: 48px;
        line-height: 1.1;
      }
    </style>
    """
  end
end

defmodule OgEx.Bench.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :og_ex
end

defmodule OgEx.Bench.PageHTML do
  @moduledoc false

  use Phoenix.Component

  def show(assigns) do
    ~H"""
    <html>
      <head><title>{@title}</title></head>
      <body><article>Normal page for {@title}.</article></body>
    </html>
    """
  end
end

defmodule OgEx.Bench.PathController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]
  use OgEx.Controller

  og_card(:show, OgEx.Bench.WideCard, image_route: :path)

  def show(conn, %{"id" => id}) do
    conn
    |> Phoenix.Controller.put_view(html: OgEx.Bench.PageHTML)
    |> render(:show, title: "Loaded post #{id}")
  end
end

defmodule OgEx.Bench.Router do
  @moduledoc false

  use Phoenix.Router
  import OgEx.Router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/" do
    pipe_through :browser

    get "/posts/:id", OgEx.Bench.PathController, :show
  end

  og_ex_routes()
end

defmodule OgEx.Bench.Env do
  @moduledoc false

  # Environment metadata recorded with every benchmark run so results stay
  # reproducible and comparable across machines and releases.
  def report(title) do
    {:ok, hostname} = :inet.gethostname()

    """
    # #{title}
    Date: #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")}
    Host: #{hostname}
    OS: #{os_name()}
    CPU: #{cpu_model()} (#{:erlang.system_info(:logical_processors_available)} logical cores)
    Memory: #{memory_total()}
    OTP: #{System.otp_release()} (erts #{:erlang.system_info(:version)})
    Elixir: #{System.version()}
    OgEx: #{Application.spec(:og_ex, :vsn) |> List.to_string()}
    Schedulers online: #{:erlang.system_info(:schedulers_online)} \
    (dirty CPU: #{:erlang.system_info(:dirty_cpu_schedulers_online)})
    Font: #{Application.get_env(:og_ex, :fonts) |> inspect()}
    """
  end

  defp os_name do
    version =
      case :os.version() do
        version when is_list(version) -> List.to_string(version)
        {major, minor, release} -> "#{major}.#{minor}.#{release}"
        other -> inspect(other)
      end

    case :os.type() do
      {:unix, name} -> "#{name} #{version}"
      {_family, name} -> "#{name} #{version}"
    end
  end

  defp cpu_model do
    case File.read("/proc/cpuinfo") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value("unknown", fn line ->
          if String.contains?(line, "model name"), do: line |> String.split(":") |> List.last()
        end)
        |> String.trim()

      _ ->
        "unknown"
    end
  end

  defp memory_total do
    case File.read("/proc/meminfo") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value("", fn line ->
          if String.starts_with?(line, "MemTotal") do
            line |> String.split() |> Enum.at(1) |> then(&"#{&1} kB")
          end
        end)

      _ ->
        "unknown"
    end
  end
end

Application.put_env(:og_ex, OgEx.Bench.Endpoint,
  secret_key_base: String.duplicate("og-ex-benchmark-secret-", 4),
  url: [scheme: "https", host: "bench.test", port: 443],
  server: false
)

{:ok, _} = Supervisor.start_link([OgEx.Bench.Endpoint], strategy: :one_for_one)

IO.write(OgEx.Bench.Env.report("OgEx baseline"))
