#!/bin/sh
# Compile droplet.applescript into idraw2svg.app (a drag-and-drop applet).
cd "$(dirname "$0")"
rm -rf idraw2svg.app
osacompile -o idraw2svg.app droplet.applescript && echo "Built idraw2svg.app"
