# Approach 2: Reusable Card Component

This approach keeps metadata in the controller action while moving image layout
into a named module. It provides the cleanest foundation for a library.

## Proposed controller API

```elixir
def show(conn, %{"id" => id}) do
  post = Blog.get_post!(id)

  conn
  |> og(
    title: post.title,
    description: post.summary,
    type: "article",
    image_alt: "Social card for #{post.title}",
    card: {MyAppWeb.PostCard, post: post}
  )
  |> render(:show, post: post)
end
```

## Proposed card component

```elixir
defmodule MyAppWeb.PostCard do
  use OgEx.Card, width: 1200, height: 630

  attr :post, :map, required: true

  def render(assigns) do
    ~OG"""
    <div style="display: flex; width: 1200px; height: 630px;
                padding: 72px; background: #0f172a; color: white;">
      <div style="display: flex; flex-direction: column; gap: 24px;">
        <img src={@post.author.avatar_url}
             style="width: 96px; height: 96px; border-radius: 48px;" />
        <h1 style="font-size: 72px;">{@post.title}</h1>
        <p style="font-size: 30px;">{@post.author.name}</p>
      </div>
    </div>
    """
  end
end
```

An initial implementation does not need a new sigil. A data-oriented component
tree is simpler to build:

```elixir
defmodule MyAppWeb.PostCard do
  use OgEx.Card, width: 1200, height: 630

  def render(%{post: post}) do
    box [display: :flex, padding: 72, background: "#0f172a"], [
      text(post.title, font_size: 72, color: "white"),
      text(post.author.name, font_size: 30, color: "white")
    ]
  end
end
```

## Root layout

```heex
<head>
  <.live_title default="Example">{assigns[:page_title]}</.live_title>
  <OgEx.meta config={assigns[:og_ex]} />
</head>
```

The component should render nothing when no card is configured.

## Explicit versioning

Social platforms cache image URLs aggressively. The API should support an
explicit version:

```elixir
og(conn,
  title: post.title,
  card: {MyAppWeb.PostCard, post: post},
  version: post.updated_at
)
```

This can create:

```text
/posts/42?__og_image=2026-07-23T10%3A30%3A00Z
```

A hash is safer and shorter:

```text
/posts/42?__og_image=7e948f81
```

## Testing

Metadata can be tested separately:

```elixir
test "adds social metadata", %{conn: conn, post: post} do
  conn = get(conn, ~p"/posts/#{post}")
  html = html_response(conn, 200)

  assert html =~ ~s(property="og:title" content="#{post.title}")
  assert html =~ ~s(name="twitter:card" content="summary_large_image")
end
```

Image behavior can be tested through a helper:

```elixir
test "serves the generated card", %{conn: conn, post: post} do
  conn = get(conn, ~p"/posts/#{post}?__og_image=test")

  assert response_content_type(conn, :png) == "image/png"
  assert byte_size(response(conn, 200)) > 0
end
```

The component itself can have renderer snapshot or pixel-difference tests.

## Advantages

- Controllers remain concise.
- Components are reusable and independently testable.
- Named modules provide useful telemetry and error messages.
- Component identity contributes naturally to cache keys.
- Compile-time attribute validation is possible.
- Multiple rendering backends can share the same component contract.

## Drawbacks

- Requires a second module.
- A true HEEx-compatible renderer is difficult because browsers support far
  more CSS than SVG or lightweight layout engines.
- Remote images and fonts introduce I/O, failure, and security concerns.

## Requirements

- An `OgEx.Card` behavior with `render/1`.
- A controller helper that stores normalized metadata and card configuration.
- A layout component that emits escaped, deduplicated tags.
- An image-request plug.
- A render backend and resource loader.
- Content-addressed caching and request coalescing.

## Recommendation

Make this the canonical internal and public API. Other approaches can translate
their card source into this contract.
