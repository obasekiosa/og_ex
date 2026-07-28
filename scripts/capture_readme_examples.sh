#!/usr/bin/env bash

set -euo pipefail

demo_url="${1:-http://127.0.0.1:4001}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${repository_root}/artifacts/examples"
capture_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${capture_dir}"
}

trap cleanup EXIT

metadata_image_url() {
  local route="$1"

  curl --fail --silent --show-error "${demo_url}${route}" |
    sed -n 's/.*<meta property="og:image" content="\([^"]*\)">.*/\1/p'
}

capture_generated_image() {
  local route="$1"
  local destination="$2"
  local image_url

  image_url="$(metadata_image_url "${route}")"

  if [[ -z "${image_url}" ]]; then
    echo "No og:image metadata found at ${demo_url}${route}" >&2
    exit 1
  fi

  curl --fail --silent --show-error "${image_url}" --output "${destination}"
}

verify_png_dimensions() {
  local path="$1"
  local expected_width="$2"
  local expected_height="$3"

  elixir -e '
    [path, expected_width, expected_height] = System.argv()
    expected_width = String.to_integer(expected_width)
    expected_height = String.to_integer(expected_height)

    case File.read!(path) do
      <<137, "PNG\r\n", 26, "\n", _length::32, "IHDR",
        ^expected_width::32, ^expected_height::32, _rest::binary>> ->
        :ok

      _ ->
        raise "#{path} is not a #{expected_width}x#{expected_height} PNG"
    end
  ' "${path}" "${expected_width}" "${expected_height}"
}

mkdir -p "${output_dir}"

capture_generated_image \
  "/embedded-local" \
  "${capture_dir}/embedded-local.png"

capture_generated_image \
  "/embedded-external" \
  "${capture_dir}/embedded-external.png"

curl --fail --silent --show-error \
  "${demo_url}/images/logo.svg" \
  --output "${capture_dir}/direct-image.svg"

verify_png_dimensions "${capture_dir}/embedded-local.png" 1200 630
verify_png_dimensions "${capture_dir}/embedded-external.png" 1200 630

if ! grep -q '<svg' "${capture_dir}/direct-image.svg"; then
  echo "The direct-image response is not SVG" >&2
  exit 1
fi

mv "${capture_dir}/embedded-local.png" "${output_dir}/embedded-local.png"
mv "${capture_dir}/embedded-external.png" "${output_dir}/embedded-external.png"
mv "${capture_dir}/direct-image.svg" "${output_dir}/direct-image.svg"

echo "Captured README examples in ${output_dir}"
