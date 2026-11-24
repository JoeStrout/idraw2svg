# idraw2svg

Converts drawings from Graphic (formerly iDraw; Intel-only, no longer runs on
Apple Silicon) to SVG, for import into Amadine, Affinity, etc.

## Usage

    miniscript idraw2svg.ms <file.idraw or folder> ...

Each `foo.idraw` becomes `foo.svg` beside it (an existing `foo.svg` is
overwritten).  Folders are searched recursively.  Unsupported features are
reported as "note:" lines per file.

## Droplet

`./make-droplet.sh` builds `idraw2svg.app`.  Drop files or folders on it (or
double-click it to pick files).  It expects MiniScript 2 at
`/usr/local/bin/miniscript` and this repo at `~/svnrepo/idraw2svg`; edit the
properties at the top of `droplet.applescript` if those move.

## Requirements

MiniScript 2, plus the macOS tools `unzip`, `plutil`, and `base64`.
`lib/` holds copies of `json.ms` and `stringUtil.ms` from MiniScript 2, so the
script works even when MiniScript has no `lib` folder next to its executable.

## The .idraw format (as far as we know)

A zip containing `data.xml` (actually a binary plist), `Images/`, and
`Thumbnails/Preview.jpg`.  The plist is converted to JSON with
`plutil -remove ColorProfile` (a data blob JSON can't hold) then
`plutil -convert json`.

- `Layers`: list of {Name, Hidden, Opacity, Shapes}; first layer is drawn first.
- Shapes: `PathShape`, `TextShape`, `ShapeGroup` (children use absolute positions).
- `Path`: SVG path data (M/L/C/Z), relative to `Position` ("{x, y}").
- `Appearance`: list of Fill / Stroke / DropShadow entries, each with `Enabled`.
  - Fill `FillType`: 1 solid, 2 gradient (Start/EndPoint in unit box), 3 image
    (`FillImage.Name` in `Images/`).
  - Stroke `LineCap`/`LineJoin`: 0/1/2 = butt/round/square, miter/round/bevel.
- Colors: `rgba(r,g,b,a)` with components 0-1.
- Text: `TextSpans` (Text, FontName (PostScript), FontSize, TextColor);
  `TextAlignment` is NSTextAlignment (0 left, 1 right, 2 center).

## Known limitations

- SVG has no text wrapping, so text boxes are pre-wrapped using estimated
  character widths; line breaks may differ from the original, and text
  imports as fixed lines rather than reflowable boxes.
- Fill transforms, non-linear gradients, and image scaling modes other than
  stretch are not yet handled (they produce a note).
