#!/usr/bin/env miniscript
// idraw2svg: convert Graphic (.idraw) drawings to SVG.
//
// Usage:  miniscript idraw2svg.ms <file-or-folder> ...
//
// Each foo.idraw becomes foo.svg next to it (overwriting any existing one).
// Folders are searched recursively for .idraw documents.
//
// An .idraw file is a zip archive holding data.xml (really a binary plist),
// an Images folder, and a Thumbnails folder.  We unzip it and convert the
// plist to JSON using the macOS command-line tools (unzip, plutil, base64),
// then translate the drawing into SVG.

import "json"
import "stringUtil"

// ----------------------------------------------------------------------
// Small helpers

// Quote a string for safe use as a single shell argument.
shq = function(s)
	return "'" + s.replace("'", "'\''") + "'"
end function

// Run a shell command; return its output, or an error if it failed.
run = function(cmd)
	r = exec(cmd, 120)
	if r.status != 0 then return err("command failed: " + cmd + char(10) + r.errors)
	return r.output
end function

// Extract all the numbers from a string like "{12, 34.5}", "rgba(1,0,0,0.5)",
// or an SVG path.
nums = function(s)
	result = []
	tok = ""
	for c in s + " "
		if "0123456789.-+eE".indexOf(c) != null then
			tok += c
		else
			if tok != "" then result.push tok.val
			tok = ""
		end if
	end for
	return result
end function

// Format a number for SVG output (at most 3 decimal places).
fmt = function(n)
	return str(round(n, 3))
end function

// Escape text for use in XML content or attribute values.
esc = function(s)
	s = str(s)
	s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
	return s.replace("""", "&quot;")
end function

// Build an XML attribute string: attr("fill", "red") -> ' fill="red"'
attr = function(name, value)
	return " " + name + "=""" + esc(value) + """"
end function

// Convert "rgba(r,g,b,a)" (components 0-1) to [cssColor, alpha].
color = function(s)
	if s == null then s = "rgba(0,0,0,1)"
	c = nums(s)
	if c.len < 4 then c.push 1
	return ["rgb(" + round(c[0]*255) + "," + round(c[1]*255) + "," + round(c[2]*255) + ")", c[3]]
end function

// Bounding box [x0, y0, x1, y1] of a path.  (Uses control points too,
// which is close enough for our purposes.)
bbox = function(path)
	n = nums(path)
	if n.len < 2 then return [0, 0, 0, 0]
	x0 = n[0]; x1 = n[0]; y0 = n[1]; y1 = n[1]
	for i in range(0, n.len - 2, 2)
		x = n[i]; y = n[i+1]
		if x < x0 then x0 = x
		if x > x1 then x1 = x
		if y < y0 then y0 = y
		if y > y1 then y1 = y
	end for
	return [x0, y0, x1, y1]
end function

// Get a value from a map, or a default if missing/null.
get = function(m, key, default=null)
	if m == null or not m.hasIndex(key) or m[key] == null then return default
	return m[key]
end function

isUpper = function(c)
	return c != c.lower
end function

isLower = function(c)
	return c != c.upper
end function

// Map a PostScript font name (e.g. "Arial-BoldItalicMT") to SVG font attributes.
fontAttrs = function(psName)
	psName = str(psName)
	dash = psName.indexOf("-")
	if dash == null then
		fam = psName; style = ""
	else
		fam = psName[:dash]; style = psName[dash+1:]
	end if
	for suffix in ["PSMT", "MT", "PS"]
		if fam.endsWith(suffix) then
			fam = fam[:-suffix.len]
			break
		end if
	end for
	// insert spaces at lowercase->uppercase transitions: TimesNewRoman -> Times New Roman
	spaced = ""
	for i in fam.indexes
		if i > 0 and isLower(fam[i-1]) and isUpper(fam[i]) then spaced += " "
		spaced += fam[i]
	end for
	weight = "normal"
	if style.contains("Semibold") or style.contains("Medium") then
		weight = "600"
	else if style.contains("Bold") or style.contains("Black") or style.contains("Heavy") then
		weight = "bold"
	end if
	italic = "normal"
	if style.contains("Italic") or style.contains("Oblique") then italic = "italic"
	return attr("font-family", spaced + ", " + psName + ", sans-serif") +
	  attr("font-weight", weight) + attr("font-style", italic)
end function

// Very rough text-width estimate, used for wrapping (SVG has no auto-wrap).
textWidth = function(s, size, bold)
	if bold then return s.len * size * 0.56
	return s.len * size * 0.5
end function

// Wrap text into lines that fit the given width.
wrap = function(text, width, size, bold)
	lines = []
	for para in text.split(char(10))
		// split into words, each keeping its trailing space
		words = para.split(" ")
		for i in range(0, words.len - 2, 1)
			words[i] += " "
		end for
		cur = ""
		for w in words
			if cur != "" and textWidth(cur + w.trimRight, size, bold) > width then
				lines.push cur
				cur = w
			else
				cur += w
			end if
		end for
		lines.push cur
	end for
	return lines
end function

// ----------------------------------------------------------------------
// Converter: holds the state for converting one document.

Converter = {}
Converter.defs = null		// list of SVG <defs> entries
Converter.nextId = 0
Converter.images = null		// image name -> data URL
Converter.warnings = null	// map of warning text -> count

Converter.init = function(workDir)
	self.defs = []
	self.warnings = {}
	self.images = {}
	imgDir = file.child(workDir, "Images")
	if not file.exists(imgDir) then return self
	for name in file.children(imgDir)
		ext = name.split(".")[-1].lower
		mime = {"png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg",
		  "gif":"image/gif", "tif":"image/tiff", "tiff":"image/tiff"}
		b64 = run("base64 -i " + shq(file.child(imgDir, name)))
		if b64 isa error then
			self.warn "could not read image " + name
			continue
		end if
		self.images[name] = "data:" + get(mime, ext, "image/" + ext) + ";base64," + b64
	end for
	return self
end function

Converter.newId = function(prefix)
	self.nextId += 1
	return prefix + self.nextId
end function

Converter.warn = function(msg)
	self.warnings[msg] = get(self.warnings, msg, 0) + 1
end function

// Text content of a TextShape at offset (x, y).
Converter.textShape = function(s, x, y)
	box = bbox(s.Path)
	w = box[2] - box[0]
	spans = get(s, "TextSpans")
	if not spans then
		spans = [{"Text": get(s, "Text", ""), "FontName": get(s, "FontName"),
		  "FontSize": get(s, "FontSize", 12)}]
	end if
	align = get(s, "TextAlignment", 0)  // NSTextAlignment: 0 left, 1 right, 2 center
	if align == 1 then
		anchor = "end"; ax = x + box[2]
	else if align == 2 then
		anchor = "middle"; ax = x + (box[0] + box[2]) / 2
	else
		anchor = "start"; ax = x + box[0]
		if align > 2 then self.warn "justified text rendered left-aligned"
	end if
	out = []
	cy = y + box[1]
	lineOpen = false
	for sp in spans
		size = get(sp, "FontSize", 12)
		fontName = get(sp, "FontName", get(s, "FontName", "Helvetica"))
		bold = fontName.contains("Bold")
		c = color(get(sp, "TextColor"))
		text = str(get(sp, "Text", ""))
		lines = wrap(text, w, size, bold)
		for i in lines.indexes
			if i > 0 or not lineOpen then
				if out then cy += size * 1.15 else cy += size * 0.95
				t = "<tspan" + attr("x", fmt(ax)) + attr("y", fmt(cy))
				lineOpen = true
			else
				t = "<tspan"
			end if
			t += fontAttrs(fontName) + attr("font-size", fmt(size)) + attr("fill", c[0])
			if c[1] < 1 then t += attr("fill-opacity", fmt(c[1]))
			out.push t + ">" + esc(lines[i]) + "</tspan>"
		end for
		lineOpen = not text.endsWith(char(10))
	end for
	return "<text" + attr("text-anchor", anchor) + " xml:space=""preserve"">" + out.join("") + "</text>"
end function

// Fill/stroke/shadow appearance of a shape at offset (x, y).
Converter.pathShape = function(s, x, y)
	d = s.Path
	parts = []
	shadow = null
	ft = get(s, "FillTransform", "[1,0,0,1,0,0]")
	m = nums(ft)
	if m.len == 6 and (abs(m[0]-1) > 0.001 or abs(m[1]) > 0.001 or abs(m[2]) > 0.001 or
	  abs(m[3]-1) > 0.001 or abs(m[4]) > 0.001 or abs(m[5]) > 0.001) then
		self.warn "fill transforms ignored"
	end if
	for a in get(s, "Appearance", [])
		if get(a, "Enabled", true) == false then continue
		kind = get(a, "Type")
		if kind == "DropShadow" then
			c = color(get(a, "Color", "rgba(0,0,0,0.5)"))
			off = nums(get(a, "Offset", "{0,0}"))
			shadow = self.newId("shadow")
			self.defs.push "<filter id=""" + shadow + """ x=""-20%"" y=""-20%"" width=""140%"" height=""140%"">" +
			  "<feDropShadow" + attr("dx", fmt(off[0])) + attr("dy", fmt(off[1])) +
			  attr("stdDeviation", fmt(get(a, "Blur", 0) / 2)) +
			  attr("flood-color", c[0]) + attr("flood-opacity", fmt(c[1])) + "/></filter>"
		else if kind == "Fill" then
			fillType = get(a, "FillType", 1)
			if fillType == 2 then
				g = a.FillGradient
				if get(g, "GradientType", 0) != 0 then self.warn "non-linear gradient rendered as linear"
				gid = self.newId("grad")
				p0 = nums(g.StartPoint); p1 = nums(g.EndPoint)
				stops = []
				for i in g.Colors.indexes
					c = color(g.Colors[i])
					stops.push "<stop" + attr("offset", fmt(g.Locations[i])) +
					  attr("stop-color", c[0]) + attr("stop-opacity", fmt(c[1])) + "/>"
				end for
				self.defs.push "<linearGradient" + attr("id", gid) +
				  attr("x1", fmt(p0[0])) + attr("y1", fmt(p0[1])) +
				  attr("x2", fmt(p1[0])) + attr("y2", fmt(p1[1])) + ">" +
				  stops.join("") + "</linearGradient>"
				parts.push "<path" + attr("d", d) + attr("fill", "url(#" + gid + ")") + "/>"
			else if fillType == 3 then
				im = a.FillImage
				if get(im, "ScalingMode", 1) != 1 then self.warn "image scaling mode " + im.ScalingMode + " treated as stretch"
				href = get(self.images, im.Name)
				if href == null then
					self.warn "missing image " + im.Name
					continue
				end if
				box = bbox(d)
				cid = self.newId("clip")
				self.defs.push "<clipPath" + attr("id", cid) + "><path" + attr("d", d) + "/></clipPath>"
				parts.push "<image" + attr("clip-path", "url(#" + cid + ")") +
				  attr("x", fmt(box[0])) + attr("y", fmt(box[1])) +
				  attr("width", fmt(box[2] - box[0])) + attr("height", fmt(box[3] - box[1])) +
				  " preserveAspectRatio=""none""" + attr("opacity", fmt(get(im, "Alpha", 1))) +
				  attr("href", href) + "/>"
			else
				if fillType != 1 then self.warn "unknown fill type " + fillType
				c = color(get(a, "FillColor"))
				t = "<path" + attr("d", d) + attr("fill", c[0])
				if c[1] < 1 then t += attr("fill-opacity", fmt(c[1]))
				parts.push t + "/>"
			end if
		else if kind == "Stroke" then
			c = color(get(a, "LineColor"))
			cap = ["butt", "round", "square"][get(a, "LineCap", 0)]
			join = ["miter", "round", "bevel"][get(a, "LineJoin", 0)]
			t = "<path" + attr("d", d) + " fill=""none""" + attr("stroke", c[0])
			if c[1] < 1 then t += attr("stroke-opacity", fmt(c[1]))
			t += attr("stroke-width", fmt(get(a, "LineWidth", 1))) +
			  attr("stroke-linecap", cap) + attr("stroke-linejoin", join) +
			  attr("stroke-miterlimit", fmt(get(a, "LineMiter", 10)))
			parts.push t + "/>"
		else
			self.warn "unknown appearance type " + kind
		end if
	end for
	g = "<g" + attr("transform", "translate(" + fmt(x) + "," + fmt(y) + ")")
	if get(s, "Opacity", 1) < 1 then g += attr("opacity", fmt(s.Opacity))
	if shadow then g += attr("filter", "url(#" + shadow + ")")
	return g + ">" + parts.join("") + "</g>"
end function

// Convert one shape (path, text, or group) to SVG.
Converter.shape = function(s)
	kind = get(s, "ShapeType", "PathShape")
	if kind == "ShapeGroup" then
		g = "<g"
		if get(s, "Opacity", 1) < 1 then g += attr("opacity", fmt(s.Opacity))
		out = [g + ">"]
		for child in get(s, "Shapes", [])
			out.push self.shape(child)
		end for
		out.push "</g>"
		return out.join(char(10))
	end if
	pos = nums(get(s, "Position", "{0,0}"))
	if kind == "TextShape" then
		// text boxes can also have a fill/stroke of their own
		result = ""
		if get(s, "Appearance") then result = self.pathShape(s, pos[0], pos[1])
		return result + self.textShape(s, pos[0], pos[1])
	end if
	if kind != "PathShape" then self.warn "unknown shape type " + kind + " treated as path"
	return self.pathShape(s, pos[0], pos[1])
end function

// Convert a whole document (parsed from data.xml) to a list of SVG lines.
Converter.document = function(doc)
	dims = nums(get(doc, "Dimensions", "{612, 792}"))
	bg = color(get(get(doc, "CanvasStyle", {}), "BackgroundColor", "rgba(1,1,1,1)"))
	body = []
	for layer in get(doc, "Layers", [])
		name = get(layer, "Name", "Layer")
		g = "<g" + attr("id", name) + attr("inkscape:groupmode", "layer") + attr("inkscape:label", name)
		if get(layer, "Hidden", false) then g += " display=""none"""
		if get(layer, "Opacity", 1) < 1 then g += attr("opacity", fmt(layer.Opacity))
		body.push g + ">"
		for s in get(layer, "Shapes", [])
			body.push self.shape(s)
		end for
		body.push "</g>"
	end for
	w = fmt(dims[0]); h = fmt(dims[1])
	out = ["<?xml version=""1.0"" encoding=""UTF-8""?>",
	  "<svg xmlns=""http://www.w3.org/2000/svg"" xmlns:xlink=""http://www.w3.org/1999/xlink""" +
	  " xmlns:inkscape=""http://www.inkscape.org/namespaces/inkscape""" +
	  attr("width", w) + attr("height", h) + attr("viewBox", "0 0 " + w + " " + h) + ">",
	  "<defs>" + self.defs.join(char(10)) + "</defs>",
	  "<rect width=""100%"" height=""100%""" + attr("fill", bg[0]) + "/>"]
	return out + body + ["</svg>"]
end function

// ----------------------------------------------------------------------
// File handling

// Convert one .idraw (zip file or package folder) to an .svg beside it.
// Returns the output path, or an error.
convertFile = function(srcPath)
	dstPath = srcPath[:-".idraw".len] + ".svg"
	tmp = run("mktemp -d -t idraw2svg")
	if tmp isa error then return tmp
	result = convertIn(srcPath, dstPath, tmp)
	run "rm -rf " + shq(tmp)
	return result
end function

convertIn = function(srcPath, dstPath, tmp)
	if file.info(srcPath).isDirectory then
		// older documents may be saved as a package folder rather than a zip
		work = srcPath
	else
		work = file.child(tmp, "doc")
		r = run("unzip -qo " + shq(srcPath) + " -d " + shq(work))
		if r isa error then return err("not a valid .idraw archive", r)
	end if
	data = file.child(work, "data.xml")
	if not file.exists(data) then return err("no data.xml inside document")
	plist = file.child(tmp, "data.plist")
	r = run("plutil -convert xml1 -o " + shq(plist) + " " + shq(data))
	if r isa error then return err("could not read document data", r)
	run "plutil -remove ColorProfile " + shq(plist)  // binary blob that JSON can't hold; may not exist
	r = run("plutil -convert json " + shq(plist))
	if r isa error then return err("could not convert document data to JSON", r)
	doc = json.parse(file.readLines(plist).join(char(10)))
	if doc isa error then return doc

	conv = (new Converter).init(work)
	lines = conv.document(doc)
	r = file.writeLines(dstPath, lines)
	if r isa error then return r
	for kv in conv.warnings
		msg = "    note: " + kv.key
		if kv.value > 1 then msg += " (" + kv.value + "x)"
		print msg
	end for
	return dstPath
end function

// Find all .idraw documents in a folder, recursively.
findDocs = function(dir, results)
	for name in file.children(dir)
		path = file.child(dir, name)
		if name.lower.endsWith(".idraw") then
			results.push path
		else if file.info(path).isDirectory then
			findDocs path, results
		end if
	end for
	return results
end function

// ----------------------------------------------------------------------
// Main program

if shellArgs.len < 2 then
	print "Usage: miniscript idraw2svg.ms <file.idraw or folder> ..."
	exit 2
end if

docs = []
for arg in shellArgs[1:]
	info = file.info(arg)
	if info == null then
		print "Not found: " + arg
	else if arg.lower.endsWith(".idraw") or arg.lower.endsWith(".idraw/") then
		docs.push arg - "/"
	else if info.isDirectory then
		findDocs arg, docs
	else
		print "Skipping (not an .idraw file): " + arg
	end if
end for

failures = 0
for path in docs
	print file.name(path)
	result = convertFile(path)
	if result isa error then
		failures += 1
		msg = "    FAILED: " + result.message
		if result.inner then msg += ": " + result.inner.message
		print msg
	else
		print "    -> " + file.name(result)
	end if
end for
print docs.len + " document(s), " + failures + " failure(s)"
if failures then exit 1
