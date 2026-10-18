import CoreGraphics
import Foundation
import ImageIO
import simd
import Vision

/// Raster image → SVG (vector tracing), for logos, icons and flat artwork. Runs on-device:
///
/// 1. Reduce the image to a small palette with k-means in Oklab (perceptual) color space.
///    In automatic mode, near-identical colors are merged so flat art keeps its real palette.
/// 2. Clean up anti-aliasing specks with a majority filter.
/// 3. Stack the colors, largest first. Each layer covers its own pixels *and* every later layer's,
///    so shapes overlap instead of meeting edge to edge: no hairline gaps between colors.
/// 4. Trace each layer's outline with Vision, simplify it, and smooth it into Bézier curves.
struct Vectorizer {
    struct Settings: Sendable, Equatable {
        /// nil = automatic (up to 16, merging near-identical colors).
        var colors: Int? = nil
        /// Outline simplification tolerance, in pixels of the processed image.
        var tolerance: Double = 1.0
        /// Images are traced at this size at most (longest side, in pixels).
        var maxDimension: Int = 1024
    }

    struct Layer {
        let color: (r: UInt8, g: UInt8, b: UInt8)
        let pathData: String
    }

    let settings: Settings

    /// SVG markup for `image`, sized to the image's pixel dimensions.
    func svg(for image: CGImage) throws -> String {
        let (width, height) = (image.width, image.height)
        let layers = try trace(image)
        var svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(width)" height="\#(height)" viewBox="0 0 \#(width) \#(height)">"#
        for layer in layers where !layer.pathData.isEmpty {
            svg += #"<path fill="\#(Self.hex(layer.color))" fill-rule="evenodd" d="\#(layer.pathData)"/>"#
        }
        return svg + "</svg>\n"
    }

    func trace(_ image: CGImage) throws -> [Layer] {
        // Work on a bounded copy; output coordinates are scaled back to the original size.
        let scale = min(1, Double(settings.maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let pixels = try Self.rgba(image, width: w, height: h)
        let outputScale = (x: Double(image.width) / Double(w), y: Double(image.height) / Double(h))

        // Opaque pixels in Oklab; transparent ones are left untraced.
        var lab = [SIMD3<Float>](repeating: .zero, count: w * h)
        var opaque = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let a = pixels[i * 4 + 3]
            guard a >= 128 else { continue }
            opaque[i] = true
            // Pixels are premultiplied; undo it before converting.
            let f = 255 / Float(a)
            lab[i] = Self.oklab(r: Float(pixels[i * 4]) * f / 255, g: Float(pixels[i * 4 + 1]) * f / 255, b: Float(pixels[i * 4 + 2]) * f / 255)
        }
        let opaqueIndices = opaque.indices.filter { opaque[$0] }
        guard !opaqueIndices.isEmpty else { throw ConversionError("The image is fully transparent.") }

        var palette = Self.kMeans(opaqueIndices.map { lab[$0] }, k: settings.colors ?? 16)
        if settings.colors == nil { palette = Self.mergeClose(palette, threshold: 0.045) }

        var labels = [Int](repeating: -1, count: w * h)
        for i in opaqueIndices { labels[i] = Self.nearest(lab[i], in: palette.map(\.center)) }
        Self.foldEdgeClusters(&labels, lab: lab, palette: palette, width: w, height: h)
        Self.majorityFilter(&labels, width: w, height: h)
        Self.dropTinyClusters(&labels, lab: lab, palette: &palette, minimumFraction: 0.0002)

        // Largest color first, so later (smaller) layers sit on top.
        var counts = [Int](repeating: 0, count: palette.count)
        for label in labels where label >= 0 { counts[label] += 1 }
        let order = counts.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }
        var rank = [Int](repeating: -1, count: palette.count)
        for (r, cluster) in order.enumerated() { rank[cluster] = r }

        // Mean source color of each cluster, for exact fills (k-means centers drift slightly).
        var sums = [SIMD3<Double>](repeating: .zero, count: palette.count)
        for i in opaqueIndices where labels[i] >= 0 {
            let f = 255 / Double(pixels[i * 4 + 3])
            sums[labels[i]] += SIMD3(Double(pixels[i * 4]) * f, Double(pixels[i * 4 + 1]) * f, Double(pixels[i * 4 + 2]) * f)
        }

        var layers: [Layer] = []
        for (r, cluster) in order.enumerated() {
            let mean = sums[cluster] / Double(max(counts[cluster], 1))
            let color = (UInt8(min(255, mean.x.rounded())), UInt8(min(255, mean.y.rounded())), UInt8(min(255, mean.z.rounded())))
            let mask = labels.map { $0 >= 0 && rank[$0] >= r }
            let path: String
            if r == 0, mask.allSatisfy({ $0 }) {
                path = "M0 0H\(image.width)V\(image.height)H0Z" // fully opaque background
            } else {
                path = try Self.outline(of: mask, width: w, height: h, tolerance: settings.tolerance, outputScale: outputScale)
            }
            layers.append(Layer(color: color, pathData: path))
        }
        return layers
    }

    // MARK: Tracing

    /// Closed, smoothed outlines of the `true` pixels, as SVG path data (even-odd: holes alternate).
    static func outline(of mask: [Bool], width w: Int, height h: Int, tolerance: Double, outputScale: (x: Double, y: Double)) throws -> String {
        // 1 px white border so shapes touching the edge still get closed contours.
        let pw = w + 2, ph = h + 2
        var gray = [UInt8](repeating: 255, count: pw * ph)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                gray[(y + 1) * pw + (x + 1)] = 0
            }
        }
        let provider = CGDataProvider(data: Data(gray) as CFData)!
        let maskImage = CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: pw,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = true
        request.contrastAdjustment = 1
        request.maximumImageDimension = max(pw, ph)
        try VNImageRequestHandler(cgImage: maskImage).perform([request])
        guard let observation = request.results?.first else { return "" }

        let epsilon = Float(tolerance / Double(max(pw, ph)))
        var data = ""
        for contour in allContours(observation.topLevelContours) {
            guard let simplified = try? contour.polygonApproximation(epsilon: epsilon) else { continue }
            let points = simplified.normalizedPoints.map { p in
                CGPoint(x: (Double(p.x) * Double(pw) - 1) * outputScale.x,
                        y: ((1 - Double(p.y)) * Double(ph) - 1) * outputScale.y)
            }
            // Merge vertices closer than ~2 px: Vision bevels corners into two close points,
            // which would otherwise read as a gentle bend instead of a corner.
            let merged = mergeClosePoints(points, distance: 2.2 * max(outputScale.x, outputScale.y))
            guard merged.count >= 3, abs(area(merged)) >= 4 * outputScale.x * outputScale.y else { continue }
            data += smoothPath(merged)
        }
        return data
    }

    static func mergeClosePoints(_ points: [CGPoint], distance: Double) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, hypot(point.x - last.x, point.y - last.y) < distance {
                result[result.count - 1] = CGPoint(x: (last.x + point.x) / 2, y: (last.y + point.y) / 2)
            } else {
                result.append(point)
            }
        }
        if result.count > 2, let first = result.first, let last = result.last, hypot(first.x - last.x, first.y - last.y) < distance {
            result[0] = CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
            result.removeLast()
        }
        return result
    }

    private static func allContours(_ contours: [VNContour]) -> [VNContour] {
        contours.flatMap { [$0] + allContours($0.childContours) }
    }

    static func area(_ points: [CGPoint]) -> Double {
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// A closed path through `points`: Catmull-Rom curves through smooth vertices,
    /// sharp corners (under ~130°) kept as corners.
    static func smoothPath(_ points: [CGPoint]) -> String {
        let n = points.count
        func p(_ i: Int) -> CGPoint { points[(i % n + n) % n] }
        let isCorner: [Bool] = (0..<n).map { i in
            let a = p(i - 1), b = p(i), c = p(i + 1)
            let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let len = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
            guard len > 0 else { return true }
            return (v1.x * v2.x + v1.y * v2.y) / len > -0.64 // angle < ~130°
        }
        var d = "M\(fmt(p(0).x)) \(fmt(p(0).y))"
        for i in 0..<n {
            let p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2)
            if isCorner[i] && isCorner[(i + 1) % n] {
                d += "L\(fmt(p2.x)) \(fmt(p2.y))"
                continue
            }
            // Catmull-Rom handles, capped at 40% of this segment so curves never overshoot.
            let segment = hypot(p2.x - p1.x, p2.y - p1.y)
            func handle(from origin: CGPoint, tangent: CGPoint) -> CGPoint {
                var t = CGPoint(x: tangent.x / 6, y: tangent.y / 6)
                let length = hypot(t.x, t.y), cap = segment * 0.4
                if length > cap, length > 0 { t = CGPoint(x: t.x * cap / length, y: t.y * cap / length) }
                return CGPoint(x: origin.x + t.x, y: origin.y + t.y)
            }
            let c1 = isCorner[i] ? p1 : handle(from: p1, tangent: CGPoint(x: p2.x - p0.x, y: p2.y - p0.y))
            let c2 = isCorner[(i + 1) % n] ? p2 : handle(from: p2, tangent: CGPoint(x: p1.x - p3.x, y: p1.y - p3.y))
            d += "C\(fmt(c1.x)) \(fmt(c1.y)) \(fmt(c2.x)) \(fmt(c2.y)) \(fmt(p2.x)) \(fmt(p2.y))"
        }
        return d + "Z"
    }

    static func fmt(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    // MARK: Color quantization

    struct Cluster { var center: SIMD3<Float>; var weight: Int }

    /// Deterministic k-means++ on (at most 40 000 sampled) colors.
    static func kMeans(_ colors: [SIMD3<Float>], k: Int) -> [Cluster] {
        let stride = max(1, colors.count / 40_000)
        let samples = Swift.stride(from: 0, to: colors.count, by: stride).map { colors[$0] }
        let k = max(1, min(k, samples.count))
        var rng = SplitMix64(seed: 0x5EED)

        var centers = [samples[Int(rng.next() % UInt64(samples.count))]]
        var distances = samples.map { simd_distance_squared($0, centers[0]) }
        while centers.count < k {
            let total = distances.reduce(0, +)
            guard total > 0 else { break } // fewer distinct colors than k
            var target = Float(Double(rng.next() % 1_000_000) / 1_000_000) * total
            var chosen = samples.count - 1
            for (i, d) in distances.enumerated() {
                target -= d
                if target <= 0 { chosen = i; break }
            }
            centers.append(samples[chosen])
            for i in samples.indices { distances[i] = min(distances[i], simd_distance_squared(samples[i], centers.last!)) }
        }

        var assignment = [Int](repeating: 0, count: samples.count)
        for _ in 0..<15 {
            var sums = [SIMD3<Float>](repeating: .zero, count: centers.count)
            var counts = [Int](repeating: 0, count: centers.count)
            for (i, s) in samples.enumerated() {
                let c = nearest(s, in: centers)
                assignment[i] = c
                sums[c] += s
                counts[c] += 1
            }
            var moved = false
            for c in centers.indices where counts[c] > 0 {
                let updated = sums[c] / Float(counts[c])
                if simd_distance_squared(updated, centers[c]) > 1e-8 { moved = true }
                centers[c] = updated
            }
            if !moved { break }
        }
        var weights = [Int](repeating: 0, count: centers.count)
        for a in assignment { weights[a] += 1 }
        return centers.indices.filter { weights[$0] > 0 }.map { Cluster(center: centers[$0], weight: weights[$0]) }
    }

    /// Repeatedly merges the two closest clusters while they're within `threshold` (Oklab distance).
    static func mergeClose(_ clusters: [Cluster], threshold: Float) -> [Cluster] {
        var clusters = clusters
        while clusters.count > 1 {
            var best: (Int, Int, Float)?
            for i in clusters.indices {
                for j in (i + 1)..<clusters.count {
                    let d = simd_distance(clusters[i].center, clusters[j].center)
                    if d < threshold, d < (best?.2 ?? .infinity) { best = (i, j, d) }
                }
            }
            guard let (i, j, _) = best else { break }
            let wi = Float(clusters[i].weight), wj = Float(clusters[j].weight)
            clusters[i].center = (clusters[i].center * wi + clusters[j].center * wj) / (wi + wj)
            clusters[i].weight += clusters[j].weight
            clusters.remove(at: j)
        }
        return clusters
    }

    static func nearest(_ color: SIMD3<Float>, in centers: [SIMD3<Float>]) -> Int {
        var best = 0
        var bestDistance = Float.infinity
        for (i, c) in centers.enumerated() {
            let d = simd_distance_squared(color, c)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Clusters covering less than `minimumFraction` of the opaque pixels are folded into
    /// their nearest neighbour: they're anti-aliasing leftovers, not real colors.
    static func dropTinyClusters(_ labels: inout [Int], lab: [SIMD3<Float>], palette: inout [Cluster], minimumFraction: Double) {
        var counts = [Int](repeating: 0, count: palette.count)
        for l in labels where l >= 0 { counts[l] += 1 }
        let total = counts.reduce(0, +)
        let keep = palette.indices.filter { Double(counts[$0]) >= Double(total) * minimumFraction }
        guard keep.count < palette.count, !keep.isEmpty else { return }
        let keptCenters = keep.map { palette[$0].center }
        for i in labels.indices where labels[i] >= 0 && !keep.contains(labels[i]) {
            labels[i] = keep[nearest(lab[i], in: keptCenters)]
        }
    }

    /// Anti-aliasing leaves thin rings of blended colors along every edge. A cluster that's
    /// almost all edge (few pixels whose 4 neighbours share its label) and small is such a
    /// ring: each of its pixels joins whichever neighbouring color it's closest to.
    static func foldEdgeClusters(_ labels: inout [Int], lab: [SIMD3<Float>], palette: [Cluster], width w: Int, height h: Int) {
        guard w > 2, h > 2, palette.count > 1 else { return }
        var counts = [Int](repeating: 0, count: palette.count)
        var interior = [Int](repeating: 0, count: palette.count)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x, l = labels[i]
                guard l >= 0 else { continue }
                counts[l] += 1
                if labels[i - 1] == l && labels[i + 1] == l && labels[i - w] == l && labels[i + w] == l { interior[l] += 1 }
            }
        }
        let total = counts.reduce(0, +)
        let edge = palette.indices.map { c in
            counts[c] > 0 && Double(interior[c]) / Double(counts[c]) < 0.15 && Double(counts[c]) < Double(total) * 0.03
        }
        guard edge.contains(true), edge.contains(false) else { return }
        let centers = palette.map(\.center)

        for _ in 0..<4 {
            var changed = false
            let source = labels
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x, l = source[i]
                    guard l >= 0, edge[l] else { continue }
                    var best = -1
                    var bestDistance = Float.infinity
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                            let n = source[ny * w + nx]
                            guard n >= 0, !edge[n] else { continue }
                            let d = simd_distance_squared(lab[i], centers[n])
                            if d < bestDistance { bestDistance = d; best = n }
                        }
                    }
                    if best >= 0 { labels[i] = best; changed = true }
                }
            }
            if !changed { break }
        }
        // Anything still unresolved (surrounded only by edge pixels) takes the nearest real color.
        let real = palette.indices.filter { !edge[$0] }
        for i in labels.indices where labels[i] >= 0 && edge[labels[i]] {
            labels[i] = real[nearest(lab[i], in: real.map { centers[$0] })]
        }
    }

    /// One pass of a 3×3 majority filter: a pixel adopts a label held by at least 5 of its 8 neighbours.
    static func majorityFilter(_ labels: inout [Int], width w: Int, height h: Int) {
        guard w > 2, h > 2 else { return }
        let source = labels
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let own = source[i]
                guard own >= 0 else { continue }
                // Only a label held by 5+ of 8 neighbours can win, and at most one can.
                let neighbours = (source[i - w - 1], source[i - w], source[i - w + 1], source[i - 1],
                                  source[i + 1], source[i + w - 1], source[i + w], source[i + w + 1])
                let n = [neighbours.0, neighbours.1, neighbours.2, neighbours.3,
                         neighbours.4, neighbours.5, neighbours.6, neighbours.7]
                for candidate in n[0...3] where candidate >= 0 && candidate != own {
                    var count = 0
                    for label in n where label == candidate { count += 1 }
                    if count >= 5 { labels[i] = candidate; break }
                }
            }
        }
    }

    // MARK: Pixels and color

    /// Premultiplied RGBA8 pixels of `image` drawn at `width`×`height`.
    static func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError("Couldn't read the image's pixels.") }
        return pixels
    }

    /// sRGB (0…1) → Oklab.
    static func oklab(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func hex(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> String {
        String(format: "#%02x%02x%02x", c.r, c.g, c.b)
    }
}

/// Small deterministic PRNG so the same image always vectorizes the same way.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Raster image → SVG through `Vectorizer`, then SVGO when enabled.
struct VectorizeConverter: Converter {
    static let inputs: Set<FileFormat> = [.png, .jpeg, .heic, .tiff, .bmp, .webp, .gif]

    func targets(for input: FileFormat) -> [FileFormat] {
        Self.inputs.contains(input) ? [.svg] : []
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError("Couldn't open the image.")
        }
        var svg = try Vectorizer(settings: options.vectorize).svg(for: image)
        progress(0.8)
        if options.optimizeSVG { svg = try await SVGOptimizer.shared.optimize(svg) }
        try Data(svg.utf8).write(to: output, options: .atomic)
        progress(1)
        return output
    }
}
