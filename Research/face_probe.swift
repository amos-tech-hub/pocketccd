// Vision face probe: prints {file, box, mean RGB, confidence} as JSON for a
// folder of exported frames, so scripts/look_acceptance.py can check skin R/G.
//
//   swiftc -O Research/face_probe.swift -o /tmp/face_probe
//   /tmp/face_probe pictures/*.JPG > faces.json
//
// Needs CLANG_MODULE_CACHE_PATH / SWIFT_MODULECACHE_PATH pointed at /tmp when
// run inside a sandboxed shell.
import Foundation
import Vision
import ImageIO
import CoreGraphics

struct FaceOut: Encodable { let file: String; let x: Double; let y: Double; let w: Double; let h: Double; let r: Double; let g: Double; let b: Double; let confidence: Double }

func analyze(_ path: String) -> [FaceOut] {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    let req = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    try? handler.perform([req])
    guard let obs = req.results else { return [] }
    let W = img.width, H = img.height
    var out: [FaceOut] = []
    // draw into RGBA buffer for sampling
    let cs = CGColorSpaceCreateDeviceRGB()
    var buf = [UInt8](repeating: 0, count: W*H*4)
    guard let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    for f in obs {
        let bb = f.boundingBox // normalized, origin bottom-left
        let cx = bb.midX, cy = bb.midY
        // sample central 50% of face
        let sw = bb.width*0.5, sh = bb.height*0.5
        let px0 = Int((cx - sw/2) * Double(W)), px1 = Int((cx + sw/2) * Double(W))
        let py0 = Int((1 - (cy + sh/2)) * Double(H)), py1 = Int((1 - (cy - sh/2)) * Double(H))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in max(0,py0)..<min(H,py1) {
            for x in max(0,px0)..<min(W,px1) {
                let i = (y*W + x)*4
                r += Double(buf[i]); g += Double(buf[i+1]); b += Double(buf[i+2]); n += 1
            }
        }
        if n > 0 { out.append(FaceOut(file: url.lastPathComponent, x: bb.minX, y: bb.minY, w: bb.width, h: bb.height, r: r/n/255, g: g/n/255, b: b/n/255, confidence: Double(f.confidence))) }
    }
    return out
}

let files = CommandLine.arguments.dropFirst()
var all: [FaceOut] = []
for f in files { all += analyze(f) }
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
if let data = try? enc.encode(all) { print(String(data: data, encoding: .utf8)!) }
