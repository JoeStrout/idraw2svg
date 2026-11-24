// textlayout: lay out text boxes with CoreText, for idraw2svg.
//
// Usage: textlayout input.json
//
// Input:  {"boxes": [{"width": w, "align": n, "spans": [{"text": s, "font": psName, "size": pts}, ...]}, ...]}
//         (align is NSTextAlignment: 0 left, 1 right, 2 center, 3 justified)
// Output: {"boxes": [{"lines": [{"x": dx, "baseline": dy, "width": w,
//                                 "runs": [{"span": i, "text": s}, ...]}, ...]}, ...],
//          "fonts": {psName: {"found": bool, "postScriptName": s, "family": s, "weight": n, "italic": bool}}}
// where x is the line's left edge relative to the box's left edge, and baseline is
// relative to the box's top edge.

import Foundation
import CoreText

struct Span: Decodable { let text: String; let font: String; let size: Double }
struct Box: Decodable { let width: Double; let align: Int; let spans: [Span] }
struct Input: Decodable { let boxes: [Box] }

guard CommandLine.arguments.count == 2,
      let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
      let input = try? JSONDecoder().decode(Input.self, from: data) else {
	FileHandle.standardError.write("usage: textlayout input.json\n".data(using: .utf8)!)
	exit(2)
}

var fontInfo: [String: [String: Any]] = [:]

func makeFont(_ name: String, _ size: Double) -> CTFont {
	let font = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
	if fontInfo[name] == nil {
		let ps = CTFontCopyPostScriptName(font) as String
		let traits = CTFontCopyTraits(font) as NSDictionary
		let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
		let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
		// map CoreText weight (-1...1) to CSS weight (100...900)
		let table: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0.0, 400),
			(0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
		var css = 400
		var best = 99.0
		for (w, c) in table where abs(w - weight) < best { best = abs(w - weight); css = c }
		fontInfo[name] = [
			"found": ps == name || CTFontCopyFamilyName(font) as String != "Helvetica",
			"postScriptName": ps,
			"family": CTFontCopyFamilyName(font) as String,
			"weight": css,
			"italic": (symbolic & CTFontSymbolicTraits.traitItalic.rawValue) != 0,
		]
	}
	return font
}

var outBoxes: [[String: Any]] = []
for box in input.boxes {
	// Build an attributed string, remembering where each span starts (in UTF-16 units).
	let attr = NSMutableAttributedString()
	var spanStarts: [Int] = []
	for span in box.spans {
		spanStarts.append(attr.length)
		attr.append(NSAttributedString(string: span.text,
			attributes: [kCTFontAttributeName as NSAttributedString.Key: makeFont(span.font, span.size)]))
	}
	let full = attr.string as NSString
	let framesetter = CTFramesetterCreateWithAttributedString(attr)
	let tall = 1_000_000.0
	let path = CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: tall), transform: nil)
	let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
	let lines = CTFrameGetLines(frame) as! [CTLine]
	var origins = [CGPoint](repeating: .zero, count: lines.count)
	CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

	let flush: CGFloat = box.align == 1 ? 1.0 : (box.align == 2 ? 0.5 : 0.0)
	var outLines: [[String: Any]] = []
	for (i, line) in lines.enumerated() {
		let range = CTLineGetStringRange(line)
		let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
		let x = CTLineGetPenOffsetForFlush(line, flush, box.width)
		// split the line's text into runs by span
		var runs: [[String: Any]] = []
		let lineStart = range.location, lineEnd = range.location + range.length
		for (si, start) in spanStarts.enumerated() {
			let end = si + 1 < spanStarts.count ? spanStarts[si + 1] : full.length
			let a = max(start, lineStart), b = min(end, lineEnd)
			if b > a {
				var text = full.substring(with: NSRange(location: a, length: b - a))
				if b == lineEnd { while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() } }
				if !text.isEmpty { runs.append(["span": si, "text": text]) }
			}
		}
		outLines.append(["x": x, "baseline": tall - origins[i].y, "width": width, "runs": runs])
	}
	outBoxes.append(["lines": outLines])
}

let out = try JSONSerialization.data(withJSONObject: ["boxes": outBoxes, "fonts": fontInfo], options: [.sortedKeys])
FileHandle.standardOutput.write(out)
