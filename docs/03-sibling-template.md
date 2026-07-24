# Approach 3: Sibling Card Template

This approach follows normal Phoenix conventions: a controller renders the HTML
page, while a nearby template defines its social image.

## Proposed action

```elixir
def show(conn, %{"id" => id}) do
  post = Blog.get_post!(id)

  conn
  |> og(
    title: post.title,
    description: post.summary,
    template: :show_og,
    assigns: [post: post]
  )
  |> render(:show, post: post)
end
```

## File layout

```text
lib/my_app_web/controllers/post_html.ex
lib/my_app_web/controllers/post_html/show.html.heex
lib/my_app_web/controllers/post_html/show_og.og.heex
```

`show_og.og.heex`:

```heex
<div style="display: flex; width: 100%; height: 100%;
            padding: 72px; background: #111827; color: white;">
  <div style="display: flex; flex-direction: column; gap: 20px;">
    <p style="font-size: 26px;">example.com</p>
    <h1 style="font-size: 72px;">{@post.title}</h1>
    <p style="font-size: 30px;">{@post.author.name}</p>
  </div>
</div>
```

An even more automatic convention could infer the card template:

```elixir
def show(conn, %{"id" => id}) do
  post = Blog.get_post!(id)

  conn
  |> og(title: post.title, description: post.summary)
  |> render(:show, post: post)
end
```

Here `render(:show, ...)` causes the library to look for
`show_og.og.heex`. Convention-only discovery should be optional because hidden
file lookup can make failures confusing.

## Compilation model

`.og.heex` should not be compiled as ordinary HTML and then passed blindly to an
SVG renderer. The library needs an `OgEx.TemplateEngine` registered for a
dedicated extension:

```elixir
config :phoenix, :template_engines,
  og: OgEx.TemplateEngine
```

The engine can parse an intentionally limited HTML/CSS subset and compile it
into the same component tree used by `OgEx.Card`.

An alternative first release could use `.og.exs` files containing the
data-oriented DSL. That would be easier to implement but less Phoenix-like.

## Shared assigns

The card renderer executes during a separate crawler request. It cannot reuse
the original request's in-memory assigns. The action must run again or the image
URL must encode enough information to reload the record.

The safest behavior is:

1. The image request reaches the same controller action.
2. The action reloads `post`.
3. `og/2` registers the card template and assigns.
4. The plug renders the card rather than the page template.

The library must document this clearly because database work occurs once for
the human page request and again for the crawler image request.

## Advantages

- Familiar Phoenix file organization.
- Controllers stay small.
- Designers can work on card markup without editing controller code.
- Templates can be precompiled and validated.
- Development file watching can regenerate previews.

## Drawbacks

- Requires a new template engine or preprocessing step.
- HEEx syntax may imply CSS/HTML compatibility that the renderer cannot honor.
- Template discovery conventions can obscure behavior.
- Editor support for `.og.heex` may require configuration.
- Page and card templates cannot share all Phoenix components unless those
  components target the restricted OG node format.

## Requirements

- A Phoenix template engine for `.og.heex`.
- A restricted markup and style specification.
- Clear compile-time errors for unsupported tags and CSS properties.
- Template discovery based on the controller view module.
- A development watcher and preview endpoint.
- The same plug, metadata, caching, and renderer infrastructure as the other
  approaches.

## Recommendation

Offer this after the card behavior and renderer are stable. It is attractive
developer experience, but it is the most compiler-heavy API.
