import XCTest
@testable import FileLens

final class BubbleLayoutTests: XCTestCase {
    func testAreaRatiosAndNoOverlaps() {
        let weights: [Double] = [1_000_000, 250_000, 100_000, 10_000, 1, 1]
        let packed = BubbleLayout(weights: weights).pack()
        XCTAssertEqual(packed.circles.count, weights.count)
        for i in weights.indices {
            let circle = packed.circles[i]
            let ratio = pow(circle.radius / packed.circles[0].radius, 2)
            XCTAssertEqual(ratio, weights[i] / weights[0], accuracy: 0.00000001)
            for j in weights.indices where j < i {
                let other = packed.circles[j]
                XCTAssertGreaterThanOrEqual(hypot(circle.center.x - other.center.x, circle.center.y - other.center.y), circle.radius + other.radius)
            }
        }
    }

    func testEightyEqualItemsRemainFiniteAndSeparate() {
        let packed = BubbleLayout(weights: Array(repeating: 100, count: 80)).pack()
        XCTAssertTrue(packed.bounds.width.isFinite)
        XCTAssertLessThan(packed.bounds.width, 2500)
        for i in packed.circles.indices {
            for j in packed.circles.indices where j < i {
                let a = packed.circles[i], b = packed.circles[j]
                XCTAssertGreaterThanOrEqual(hypot(a.center.x - b.center.x, a.center.y - b.center.y), a.radius + b.radius)
            }
        }
    }
}
