use std::sync::Arc;

use regex_lite::Regex;
use rustler::{Atom, Binary, Encoder, Env, NewBinary, NifMap, NifResult, Term};
use takumi::{
    from_html,
    prelude::{
        FontResource, Fonts, FromHtmlOptions, OutputFormat, Quality, RenderOptions, StyleSheet,
        SvgOptions, Viewport,
    },
    render as render_node, render_svg, write_image,
};

// Atoms are initialized once by Rustler and reused without allocating strings
// for every native call.
mod atoms {
    rustler::atoms! {
        ok,
        error,
        png,
        jpeg,
        webp,
        svg
    }
}

#[derive(NifMap)]
// Rustler decodes the Elixir options map directly into this structure. Font
// binaries remain borrowed from the calling BEAM process for the duration of
// the dirty NIF call.
struct NativeRenderOptions<'a> {
    width: u32,
    height: u32,
    format: Atom,
    fonts: Vec<Binary<'a>>,
}

#[rustler::nif(schedule = "DirtyCpu")]
// Layout, text shaping, raster painting, and encoding are CPU-heavy. DirtyCpu
// keeps this work away from the BEAM's latency-sensitive normal schedulers.
/// Decodes an Elixir HTML/options request and returns an encoded image tuple.
///
/// The function executes on Rustler's dirty CPU scheduler and is the only
/// native function exported to Elixir.
fn render_html<'a>(
    env: Env<'a>,
    html: &str,
    options: NativeRenderOptions<'a>,
) -> NifResult<Term<'a>> {
    match render(html, &options) {
        Ok(bytes) => {
            // Allocate the result in an Erlang-managed binary and copy the
            // encoded bytes once. The returned binary can be sent directly by
            // Plug without a base64 round trip.
            let mut output = NewBinary::new(env, bytes.len());
            output.as_mut_slice().copy_from_slice(&bytes);
            let output: Binary<'a> = output.into();
            Ok((atoms::ok(), output).encode(env))
        }
        Err(reason) => Ok((atoms::error(), reason).encode(env)),
    }
}

/// Parses, lays out, paints, and encodes one HTML card.
///
/// Errors are flattened to strings at the NIF boundary so Rust error types
/// never leak into the Erlang term contract.
fn render(html: &str, options: &NativeRenderOptions<'_>) -> Result<Vec<u8>, String> {
    // Reject nonsensical viewports before allocating Takumi layout structures.
    if options.width == 0 || options.height == 0 {
        return Err("width and height must be greater than zero".to_string());
    }

    // Takumi's HTML helper understands elements, inline styles, class/id
    // attributes, and Tailwind's `tw` attribute. Stylesheet blocks are handled
    // separately below because the helper intentionally drops <style> nodes.
    let node = from_html(html, FromHtmlOptions::default()).map_err(|error| error.to_string())?;

    // Parse every card-local <style> block into Takumi's selector/cascade
    // engine. This preserves the familiar HEEx + CSS authoring experience.
    let stylesheets = extract_stylesheets(html)?;
    let stylesheet =
        StyleSheet::parse_list(stylesheets.iter()).map_err(|error| error.to_string())?;

    let mut fonts = Fonts::default();
    for font in &options.fonts {
        // Registration decodes WOFF/WOFF2 when necessary and makes the faces
        // available to Takumi's shaping and fallback machinery.
        fonts
            .register(FontResource::new(font.as_slice()))
            .map_err(|error| error.to_string())?;
    }

    if options.fonts.is_empty() {
        return Err(
            "no fonts configured; pass at least one TTF, OTF, WOFF, or WOFF2 font".to_string(),
        );
    }

    // SVG uses the same parsed node tree, font context, stylesheet, and layout
    // engine as raster output, then emits vector primitives and glyph paths.
    if options.format == atoms::svg() {
        let svg_options = SvgOptions::builder()
            .viewport(Viewport::new((options.width, options.height)))
            .node(node)
            .fonts(&fonts)
            .stylesheet(Arc::new(stylesheet))
            .build();

        return render_svg(svg_options)
            .map(String::into_bytes)
            .map_err(|error| error.to_string());
    }

    // The same node tree, font context, and stylesheet drive raster layout and
    // painting.
    let render_options = RenderOptions::builder()
        .viewport(Viewport::new((options.width, options.height)))
        .node(node)
        .fonts(&fonts)
        .stylesheet(Arc::new(stylesheet))
        .build();

    // Takumi returns an RGBA bitmap. Encoding is kept inside the dirty NIF so a
    // multi-megabyte raw pixel buffer never has to cross into Elixir.
    let bitmap = render_node(render_options).map_err(|error| error.to_string())?;
    let format = output_format(options.format)?;
    let mut encoded = Vec::new();

    write_image(&bitmap, &mut encoded, format).map_err(|error| error.to_string())?;

    Ok(encoded)
}

/// Extracts the contents of every card-local `<style>` block.
///
/// Takumi's HTML helper intentionally removes style nodes, so the extracted CSS
/// is supplied separately to its stylesheet parser and cascade engine.
fn extract_stylesheets(html: &str) -> Result<Vec<String>, String> {
    // HEEx emits trusted, well-formed card markup. A focused extractor is
    // sufficient here because Takumi's HTML parser will independently parse
    // the element tree and discard the style nodes themselves.
    let pattern = Regex::new(r"(?is)<style(?:\s[^>]*)?>(.*?)</style\s*>")
        .map_err(|error| error.to_string())?;

    Ok(pattern
        .captures_iter(html)
        .filter_map(|captures| captures.get(1))
        .map(|capture| capture.as_str().to_string())
        .collect())
}

/// Converts an Elixir format atom into Takumi's encoder configuration.
///
/// Lossy formats currently use a fixed quality of 85.
fn output_format(format: Atom) -> Result<OutputFormat, String> {
    // Lossy formats use a sensible first-release default. Quality can become a
    // card option later without changing the NIF's response shape.
    if format == atoms::png() {
        Ok(OutputFormat::Png)
    } else if format == atoms::jpeg() {
        Ok(OutputFormat::Jpeg {
            quality: Quality::new(85),
        })
    } else if format == atoms::webp() {
        Ok(OutputFormat::WebP {
            quality: Quality::new(85),
        })
    } else {
        Err("format must be :png, :jpeg, :webp, or :svg".to_string())
    }
}

rustler::init!("Elixir.OgEx.Native");
