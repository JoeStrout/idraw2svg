#!/bin/sh
# Build the textlayout helper (CoreText text measurement) and compile
# droplet.applescript into idraw2svg.app (a drag-and-drop applet).
set -e
cd "$(dirname "$0")"
swiftc -O -o textlayout textlayout.swift && echo "Built textlayout"
rm -rf idraw2svg.app
osacompile -o idraw2svg.app droplet.applescript && echo "Built idraw2svg.app"
