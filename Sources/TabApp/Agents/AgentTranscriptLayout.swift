import Foundation

/// Lightweight estimated row geometry. Updates and position lookups never touch TextKit.
struct AgentTranscriptLayout {
    private(set) var heights: [CGFloat] = []
    private var sums: [CGFloat] = [0]
    var leading: CGFloat = 28
    let spacing: CGFloat = 26

    var count: Int { heights.count }
    var height: CGFloat { count == 0 ? 214 : leading + prefix(count) + 4 }

    mutating func reset(heights: [CGFloat]) {
        self.heights = heights.map { max(1, $0) }
        sums = Array(repeating: 0, count: heights.count + 1)
        for index in self.heights.indices {
            let position = index + 1
            sums[position] += self.heights[index] + spacing
            let parent = position + (position & -position)
            if parent < sums.count { sums[parent] += sums[position] }
        }
    }

    mutating func setHeight(_ height: CGFloat, at index: Int) {
        let height = max(1, height)
        let delta = height - heights[index]
        heights[index] = height
        var position = index + 1
        while position < sums.count {
            sums[position] += delta
            position += position & -position
        }
    }

    func top(at index: Int) -> CGFloat { leading + prefix(index) }

    func index(at offset: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        let target = max(0, offset - leading)
        var position = 0
        var sum: CGFloat = 0
        var step = 1
        while step <= count / 2 { step *= 2 }
        while step > 0 {
            let next = position + step
            if next <= count, sum + sums[next] <= target {
                position = next
                sum += sums[next]
            }
            step /= 2
        }
        return min(position, count - 1)
    }

    func rows(in rect: CGRect) -> Range<Int> {
        guard rect.height > 0, let first = index(at: rect.minY), let last = index(at: rect.maxY) else { return 0..<0 }
        return first..<min(count, last + 1)
    }

    private func prefix(_ count: Int) -> CGFloat {
        var position = count
        var total: CGFloat = 0
        while position > 0 {
            total += sums[position]
            position -= position & -position
        }
        return total
    }
}

/// A logical position survives row-view eviction, prepending history, and regrouping elsewhere.
struct AgentTranscriptAnchor {
    var rowID: String?
    var localOffset: CGFloat
    var fallback: CGFloat
}
