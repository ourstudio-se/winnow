#!/usr/bin/env bash
# Generate a Zig source file that embeds frontend assets via @embedFile.
#
# Usage: embed-frontend.sh <dist-dir> <output-zig-file>
#
# The dist-dir path in the generated @embedFile calls is relative to the
# output file's directory. E.g. if output is src/static_assets.zig and
# dist is at frontend-dist/, the paths become "../frontend-dist/...".

set -euo pipefail

DIST_DIR="$1"
OUTPUT="$2"

if [ ! -d "$DIST_DIR" ]; then
  echo "error: dist directory '$DIST_DIR' does not exist" >&2
  exit 1
fi

# Compute relative path from output file's directory to dist dir
OUTPUT_DIR="$(dirname "$OUTPUT")"
REL_DIST="$(realpath -s --relative-to="$OUTPUT_DIR" "$DIST_DIR")"

# Map file extension to MIME type
mime_type() {
  case "$1" in
    *.html) echo "text/html" ;;
    *.js)   echo "application/javascript" ;;
    *.css)  echo "text/css" ;;
    *.svg)  echo "image/svg+xml" ;;
    *.woff2) echo "font/woff2" ;;
    *.woff) echo "font/woff" ;;
    *.ttf)  echo "font/ttf" ;;
    *.png)  echo "image/png" ;;
    *.ico)  echo "image/x-icon" ;;
    *.json) echo "application/json" ;;
    *.txt)  echo "text/plain" ;;
    *.webmanifest) echo "application/manifest+json" ;;
    *)      echo "application/octet-stream" ;;
  esac
}

# Sanitize a file path into a valid Zig identifier
# e.g. "assets/index-Bp5HCeor.js" -> "assets_index_Bp5HCeor_js"
sanitize_ident() {
  echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/^_//' | sed 's/__*/_/g'
}

{
  echo "const std = @import(\"std\");"
  echo ""
  echo "pub const Asset = struct {"
  echo "    content: []const u8,"
  echo "    content_type: []const u8,"
  echo "    cacheable: bool,"
  echo "};"
  echo ""

  # Collect files and generate @embedFile consts
  declare -a files=()
  declare -a idents=()
  declare -a url_paths=()
  declare -a mimes=()
  declare -a cacheables=()

  while IFS= read -r -d '' file; do
    rel="${file#"$DIST_DIR"/}"
    files+=("$rel")
    ident="$(sanitize_ident "$rel")"
    idents+=("$ident")
    url_paths+=("/$rel")
    mimes+=("$(mime_type "$rel")")
    # Files under assets/ have content-hashed names -> cacheable
    if [[ "$rel" == assets/* ]]; then
      cacheables+=("true")
    else
      cacheables+=("false")
    fi
  done < <(find -L "$DIST_DIR" -type f -print0 | sort -z)

  # Emit @embedFile constants
  for i in "${!files[@]}"; do
    echo "const ${idents[$i]} = @embedFile(\"${REL_DIST}/${files[$i]}\");"
  done

  echo ""
  echo "const Entry = struct { path: []const u8, asset: Asset };"
  echo ""
  echo "const assets = [_]Entry{"

  # Add "/" alias for index.html
  for i in "${!files[@]}"; do
    if [ "${files[$i]}" = "index.html" ]; then
      echo "    .{ .path = \"/\", .asset = .{ .content = ${idents[$i]}, .content_type = \"${mimes[$i]}\", .cacheable = false } },"
      break
    fi
  done

  # Add all files
  for i in "${!files[@]}"; do
    echo "    .{ .path = \"/${files[$i]}\", .asset = .{ .content = ${idents[$i]}, .content_type = \"${mimes[$i]}\", .cacheable = ${cacheables[$i]} } },"
  done

  echo "};"
  echo ""
  echo "pub fn lookup(path: []const u8) ?Asset {"
  echo "    for (&assets) |*entry| {"
  echo "        if (std.mem.eql(u8, entry.path, path)) return entry.asset;"
  echo "    }"
  echo "    return null;"
  echo "}"
} > "$OUTPUT"

echo "Generated $OUTPUT with ${#files[@]} embedded assets"
