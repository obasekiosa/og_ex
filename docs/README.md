# Embedded OG for Phoenix: Design Approaches

This directory explores APIs for an Elixir/Phoenix library that configures social
metadata and serves a generated Open Graph image from the same page action.

The intended developer experience is:

1. Configure the card where the page data is loaded.
2. Automatically add Open Graph and Twitter/X metadata to the HTML `<head>`.
3. Automatically expose an image response without writing a second controller.
4. Cache generated images safely.

## Approaches

| Document | Configuration location | Best fit |
| --- | --- | --- |
| [01 — Inline controller](01-inline-controller.md) | Controller action | Small cards and the smallest possible API |
| [02 — Reusable card component](02-reusable-component.md) | Controller action plus card module | Reuse, testing, and larger cards |
| [03 — Sibling card template](03-sibling-template.md) | Controller plus `.og.heex` file | Phoenix-style template organization |
| [04 — LiveView integration](04-liveview.md) | `mount/3` or `handle_params/3` | LiveView pages and live metadata updates |
| [05 — Implementation architecture](05-implementation.md) | Library internals | Routing, rendering, dependencies, caching, and security |

## Suggested starting point

The recommended public API is an OgEx-aware `render/3` call:

```elixir
def show(conn, %{"id" => id}) do
  post = Blog.get_post!(id)

  render(conn, :show, post: post, og: MyAppWeb.PostOgCard)
end
```

The named card owns both metadata and its HEEx/HTML presentation:

```elixir
defmodule MyAppWeb.PostOgCard do
  use OgEx.Card, width: 1200, height: 630

  def metadata(%{post: post}) do
    %{title: post.title, description: post.summary}
  end

  def render(assigns) do
    ~H"""
    <main class="card">
      <h1>{@post.title}</h1>
    </main>
    """
  end
end
```

An application-wide `plug OgEx` installation injects the resulting tags before
`</head>` and recognizes signed image requests on the same page URL. Application
code does not define an image route, image controller, layout component, cache
key, or loader callback.

The library can still provide inline and sibling-template forms as alternate
card sources. They should use the same rendering pipeline.

A complete single-file application example is available at
[`examples/recommended_controller_example.ex`](../examples/recommended_controller_example.ex).
It includes the one-time installation, router, page controller, HTML/HEEx card,
page view, and root layout. The image controller and route are intentionally
absent because OgEx owns that behavior.

[`examples/og_ex_internals_example.ex`](../examples/og_ex_internals_example.ex)
shows how OgEx can implement the automatic behavior: render dispatch, signed
same-route image requests, HEEx conversion, Chromium screenshots, PNG caching,
response headers, and metadata injection.

## Important constraint

Social crawlers make a second HTTP request for `og:image`. The image cannot
literally be returned in the same HTTP response as the HTML page. “Same route”
therefore means one page action and no user-defined image action, with the
library internally recognizing a reserved image URL such as:

```text
GET /posts/123
GET /posts/123?__og_image=v1
```

Alternatively, router integration can expose:

```text
GET /posts/123/__og__/v1.png
```
