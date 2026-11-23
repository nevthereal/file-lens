import SwiftUI

/// Packing preserves the area ratio: radius is proportional to sqrt(bytes).
struct BubbleLayout: Layout {
    var weights: [Double]
    struct Cache {
        var circles: [(center: CGPoint, radius: Double)]
        var bounds: CGRect
    }
    func makeCache(subviews: Subviews) -> Cache { pack() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = pack() }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 600)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard !cache.circles.isEmpty else { return }
        let scale = min(max(1, bounds.width - 50) / cache.bounds.width, max(1, bounds.height - 50) / cache.bounds.height)
        for (index, view) in subviews.enumerated() where index < cache.circles.count {
            let circle = cache.circles[index]
            let center = CGPoint(x: bounds.midX + (circle.center.x - cache.bounds.midX) * scale,
                                 y: bounds.midY + (circle.center.y - cache.bounds.midY) * scale)
            let diameter = circle.radius * 2 * scale
            view.place(at: center, anchor: .center, proposal: ProposedViewSize(width: diameter, height: diameter))
        }
    }
    func pack() -> Cache {
        guard let maximum = weights.max(), maximum > 0 else { return Cache(circles: [], bounds: .zero) }
        let radii = weights.map { sqrt($0 / maximum) * 100 }
        var circles: [(center: CGPoint, radius: Double)] = []
        for radius in radii {
            if circles.isEmpty { circles.append((.zero, radius)); continue }
            var best = CGPoint(x: 10000, y: 10000)
            var score = Double.infinity
            for circle in circles {
                for step in 0..<48 {
                    let angle = Double(step) * .pi * 2 / 48
                    let distance = circle.radius + radius + 3
                    let point = CGPoint(x: circle.center.x + cos(angle) * distance, y: circle.center.y + sin(angle) * distance)
                    let candidateScore = hypot(point.x, point.y) + radius
                    guard candidateScore < score else { continue }
                    if circles.allSatisfy({ hypot(point.x - $0.center.x, point.y - $0.center.y) >= radius + $0.radius + 2.9 }) {
                        best = point
                        score = candidateScore
                    }
                }
            }
            circles.append((best, radius))
        }
        let rect = circles.reduce(CGRect.null) { $0.union(CGRect(x: $1.center.x - $1.radius, y: $1.center.y - $1.radius, width: $1.radius * 2, height: $1.radius * 2)) }
        return Cache(circles: circles, bounds: rect)
    }
}
