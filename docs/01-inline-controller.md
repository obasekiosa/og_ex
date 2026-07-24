# Approach 1: Inline Controller Card

This approach declares metadata and the image layout directly in the controller
action. It optimizes for locality and minimal setup.

## Proposed API

```elixir
def show(conn, %{"id" => id}) do
  post = Blog.get_post!(id)

  conn
  |> og(
    title: post.title,
    description: post.summary,
    image_alt: "Social card for #{post.title}",
    card: fn assigns ->
      ~OG"""
      <div style="display: flex; width: 100%; height: 100%;
                  padding: 72px; background: #111827; color: white;">
        <div style="display: flex; flex-direction: column;">
          <p style="font-size: 28px;">#{assigns.site_name}</p>
          <h1 style="font-size: 72px;">#{assigns.post.title}</h1>
          <p style="font-size: 30px;">#{assigns.post.author.name}</p>
        </div>
      </div>
      """
    end,
    assigns: %{post: post, site_name: "Example"}
  )
  |> render(:show, post: post)
end
```

The root layout contains a single permanent integration point:

```heex
<head>
  <meta charset="utf-8" />
  <OgEx.meta config={@og_ex} />
</head>
```

## Resulting requests

The normal request:

```http
GET /posts/42
Accept: text/html
```

returns the page with:

```html
<meta property="og:title" content="Building with Phoenix">
<meta property="og:description" content="A practical introduction">
<meta property="og:type" content="article">
<meta property="og:image"
      content="https://example.com/posts/42?__og_image=v1">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt"
      content="Social card for Building with Phoenix">

<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Building with Phoenix">
<meta name="twitter:description" content="A practical introduction">
<meta name="twitter:image"
      content="https://example.com/posts/42?__og_image=v1">
```

The crawler then requests:

```http
GET /posts/42?__og_image=v1
Accept: image/*
```

and receives:

```http
HTTP/1.1 200 OK
Content-Type: image/png
Cache-Control: public, max-age=31536000, immutable
ETag: "..."
```

## Internal behavior

`og/2` stores a normalized `%OgEx.Config{}` in `conn.assigns`. A library
plug detects the reserved image request. It allows the normal action to load its
data and declare the card, but replaces the HTML rendering phase with image
rendering.

The image response must short-circuit before the normal Phoenix template is
encoded. This likely requires `register_before_send/2`, a custom render hook, or
an endpoint/router plug that dispatches image requests through a controlled
internal pipeline.

## Advantages

- Page data and card definition are in one place.
- No additional module or file is needed.
- Easy to understand for small applications.
- The same helper can set sensible defaults for Twitter/X metadata.

## Drawbacks

- Large controller actions become difficult to read.
- An anonymous function is harder to identify in logs and cache manifests.
- Compilation and template diagnostics may be worse than named components.
- Reusing a card layout requires extracting a function or module.
- A custom `~OG` sigil requires a compiler/parser implementation.

## Requirements

- A `use OgEx.Controller` import or a helper imported by `MyAppWeb`.
- A root-layout metadata component.
- An endpoint/router plug for reserved image requests.
- A renderer that accepts the inline card representation.
- Stable cache-key generation from template identity, assigns, size, and format.
- Validation that only supported layout/style features are used.

## Recommendation

Support this as convenience syntax, but compile or normalize it into the same
named card representation used by the reusable-component approach.
