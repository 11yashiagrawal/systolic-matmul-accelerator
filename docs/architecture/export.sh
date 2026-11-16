#!/bin/sh
# Export the editable sources using the same pinned renderer for SVG and PNG.
set -eu
cd "$(dirname "$0")"
mkdir -p svg png
for source in src/*.mmd; do
    name=$(basename "$source" .mmd)
    for format in svg png; do
        npx --yes --package=@mermaid-js/mermaid-cli@11.12.0 mmdc \
            --input "$source" --output "$format/$name.$format" \
            --configFile src/mermaid-config.json --backgroundColor white \
            --width 2400 --scale 2
    done
done
