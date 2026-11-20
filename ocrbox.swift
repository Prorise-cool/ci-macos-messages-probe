import Foundation
import Vision
import AppKit

let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage else { print("NOIMG"); exit(1) }
let W = CGFloat(cg.width), H = CGFloat(cg.height)
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
req.automaticallyDetectsLanguage = false
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([req]) } catch { print("ERR"); exit(1) }
for obs in req.results ?? [] {
  guard let c = obs.topCandidates(1).first else { continue }
  let b = obs.boundingBox
  let cx = (b.origin.x + b.size.width / 2.0) * W
  let cy = (1.0 - (b.origin.y + b.size.height / 2.0)) * H
  let w = b.size.width * W
  let h = b.size.height * H
  print(String(format: "BOX\t%.0f\t%.0f\t%.0f\t%.0f\t%@", cx, cy, w, h, c.string))
}
