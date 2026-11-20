import Foundation
import Vision
import AppKit
import CoreImage

let p = CommandLine.arguments[1]
guard let src = CIImage(contentsOf: URL(fileURLWithPath: p)) else { print("NOIMG"); exit(1) }
let ctx = CIContext()

func render(_ img: CIImage, scale: CGFloat) -> CGImage? {
    let s = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return ctx.createCGImage(s, from: s.extent)
}

func ocr(_ cg: CGImage, level: VNRequestTextRecognitionLevel, minH: Float) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.usesLanguageCorrection = false
    req.automaticallyDetectsLanguage = false
    req.minimumTextHeight = minH
    let h = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try h.perform([req]) } catch { return "" }
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

var variants: [(String, CIImage)] = []
variants.append(("orig", src))
let gray = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: src, kCIInputSaturationKey: 0.0, kCIInputContrastKey: 2.4, kCIInputBrightnessKey: 0.02])!.outputImage!
variants.append(("gray2.4", gray))
let inv = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: gray])!.outputImage!
variants.append(("grayinv", inv))
let sharp = CIFilter(name: "CISharpenLuminance", parameters: [kCIInputImageKey: gray, kCIInputSharpnessKey: 0.8])!.outputImage!
variants.append(("graysharp", sharp))

var best = ""
for (name, v) in variants {
    for scale in [4.0, 8.0] as [CGFloat] {
        guard let cg = render(v, scale: scale) else { continue }
        for (lv, mh) in [(VNRequestTextRecognitionLevel.accurate, Float(0.0)), (VNRequestTextRecognitionLevel.fast, Float(0.0))] {
            let t = ocr(cg, level: lv, minH: mh).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                print("\(name)x\(Int(scale))/\(lv == .accurate ? "acc" : "fast"): \(t)")
                let cleaned = t.filter { $0.isLetter || $0.isNumber }
                if cleaned.count > best.filter({ $0.isLetter || $0.isNumber }).count { best = t }
            }
        }
    }
}
print("BEST:" + best)
