#!/bin/bash
# Generates a standard macOS .icns fallback from the Icon Composer document.
set -euo pipefail

cd "$(dirname "$0")/.."

ICON_DIR="${1:-Sources/ChzzkDownloader/cdm.icon}"
OUTPUT="${2:-Sources/ChzzkDownloader/Resources/cdm.icns}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -d "$ICON_DIR" ]; then
  echo "error: icon composer document not found: $ICON_DIR" >&2
  exit 1
fi

BASE_PNG="$TMP_DIR/cdm-1024.png"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

if [ -x "$ICTOOL" ]; then
  if "$ICTOOL" "$ICON_DIR" \
    --export-image \
    --output-file "$BASE_PNG" \
    --platform macOS \
    --rendition Default \
    --width 1024 \
    --height 1024 \
    --scale 1 >"$TMP_DIR/ictool.log" 2>&1 && [ -s "$BASE_PNG" ]; then
    :
  else
    rm -f "$BASE_PNG"
  fi
fi

if [ ! -s "$BASE_PNG" ]; then
  COMPOSED_SVG="$TMP_DIR/cdm-composed.svg"
  /usr/bin/ruby -rjson - "$ICON_DIR" "$COMPOSED_SVG" <<'RUBY'
icon_dir, output = ARGV
data = JSON.parse(File.read(File.join(icon_dir, "icon.json")))
layers = data.fetch("groups", []).flat_map { |group| group.fetch("layers", []) }
layer = layers.find { |candidate| candidate["image-name"] }
abort "error: no image layer found in #{icon_dir}" unless layer

source = File.join(icon_dir, "Assets", layer.fetch("image-name"))
svg = File.read(source)
inner = svg.sub(/\A.*?<svg\b[^>]*>/m, "").sub(%r{</svg>\s*\z}m, "")
inner = inner.gsub("currentColor", "#000000")

fill = data.dig("fill", "automatic-gradient") || "extended-srgb:0,0.78431,0.70196,1"
components = fill.split(":", 2).last.split(",").map(&:to_f)
r, g, b = components[0, 3].map { |value| [[value, 0.0].max, 1.0].min }

mix = lambda do |base, other, amount|
  ((base * (1.0 - amount) + other * amount) * 255).round
end

top = "#%02X%02X%02X" % [mix.call(r, 1.0, 0.32), mix.call(g, 1.0, 0.32), mix.call(b, 1.0, 0.32)]
bottom = "#%02X%02X%02X" % [mix.call(r, 0.0, 0.10), mix.call(g, 0.0, 0.10), mix.call(b, 0.0, 0.10)]
tx, ty = layer.dig("position", "translation-in-points") || [0, 0]
scale = layer.dig("position", "scale") || 1

File.write(output, <<~SVG)
  <svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#{top}"/>
        <stop offset="1" stop-color="#{bottom}"/>
      </linearGradient>
      <clipPath id="mask">
        <rect x="0" y="0" width="1024" height="1024" rx="192"/>
      </clipPath>
    </defs>
    <g clip-path="url(#mask)">
      <rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>
      <g transform="translate(#{tx} #{ty}) scale(#{scale})">
        #{inner}
      </g>
    </g>
  </svg>
SVG
RUBY

  RENDER_DIR="$TMP_DIR/render"
  mkdir -p "$RENDER_DIR"
  /usr/bin/qlmanage -t -s 1024 -o "$RENDER_DIR" "$COMPOSED_SVG" >/dev/null 2>&1
  RENDERED_PNG="$RENDER_DIR/$(basename "$COMPOSED_SVG").png"
  if [ ! -s "$RENDERED_PNG" ]; then
    RENDERED_PNG="$(find "$RENDER_DIR" -type f -name "*.png" -print -quit)"
  fi
  if [ -z "${RENDERED_PNG:-}" ] || [ ! -s "$RENDERED_PNG" ]; then
    echo "error: failed to render $COMPOSED_SVG" >&2
    exit 1
  fi
  cp "$RENDERED_PNG" "$BASE_PNG"
fi

ICONSET="$TMP_DIR/cdm.iconset"
mkdir -p "$ICONSET"

make_icon() {
  local pixels="$1"
  local name="$2"
  /usr/bin/sips -z "$pixels" "$pixels" "$BASE_PNG" --out "$ICONSET/$name" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

mkdir -p "$(dirname "$OUTPUT")"
/usr/bin/iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Generated: $OUTPUT"
