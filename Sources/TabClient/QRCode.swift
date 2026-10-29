import Foundation

/// A QR code for pairing links: byte mode, error correction level M,
/// versions 1 to 10 (up to 213 bytes), with the mask that scores best under
/// the standard's penalty rules.
public struct QRCode: Hashable, Sendable {
    /// Modules scanners need around the code.
    public static let quietZone = 4

    public let version: Int
    /// Modules per side, without the quiet zone.
    public let size: Int
    public let mask: Int
    private var modules: [Bool]

    /// `nil` when `text` is longer than version 10 holds.
    public init?(_ text: String) {
        self.init(bytes: Array(text.utf8))
    }

    public init?(bytes: [UInt8]) {
        self.init(bytes: bytes, forcedMask: nil)
    }

    /// With `forcedMask`, uses that mask instead of the best scoring one.
    init?(bytes: [UInt8], forcedMask: Int?) {
        guard let version = (1 ... 10).first(where: { Self.fits(bytes.count, version: $0) }) else { return nil }
        var builder = Builder(version: version)
        builder.drawFunctionPatterns()
        builder.drawCodewords(Self.codewords(bytes, version: version))
        var best = forcedMask ?? 0
        var bestPenalty = Int.max
        for mask in 0 ..< 8 where forcedMask == nil {
            builder.applyMask(mask)
            builder.drawFormatBits(mask: mask)
            let penalty = builder.penalty()
            if penalty < bestPenalty {
                best = mask
                bestPenalty = penalty
            }
            builder.applyMask(mask)
        }
        builder.applyMask(best)
        builder.drawFormatBits(mask: best)
        self.version = version
        size = builder.size
        mask = best
        modules = builder.modules
    }

    /// Whether a module is dark; positions outside the code are light.
    public func isDark(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < size && y < size && modules[y * size + x]
    }

    /// The code for a terminal, two module rows per line with half blocks,
    /// dark on light whatever the terminal's colors, quiet zone included.
    public var terminalText: String {
        let zone = Self.quietZone
        let span = size + 2 * zone
        var lines: [String] = []
        for y in stride(from: 0, to: span, by: 2) {
            var line = "\u{1B}[30;47m"
            for x in 0 ..< span {
                let top = isDark(x: x - zone, y: y - zone)
                let bottom = y + 1 < span && isDark(x: x - zone, y: y + 1 - zone)
                let glyph = switch (top, bottom) {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
                line += glyph
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Tables for level M

    /// Error correction codewords per block, by version.
    static let eccPerBlock = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26]
    /// Error correction blocks, by version.
    static let blocks = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5]
    static let alignment: [[Int]] = [
        [], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    ]

    /// Codewords a version holds, data and error correction.
    static func rawCodewords(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let count = version / 7 + 2
            result -= (25 * count - 10) * count - 55
            if version >= 7 { result -= 36 }
        }
        return result / 8
    }

    static func dataCodewords(_ version: Int) -> Int {
        rawCodewords(version) - eccPerBlock[version] * blocks[version]
    }

    static func fits(_ count: Int, version: Int) -> Bool {
        let countBits = version < 10 ? 8 : 16
        return count < 1 << countBits && 4 + countBits + 8 * count <= dataCodewords(version) * 8
    }

    /// The data in byte mode, padded, split into blocks with their error
    /// correction, and interleaved.
    static func codewords(_ bytes: [UInt8], version: Int) -> [UInt8] {
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> shift) & 1 == 1) }
        }
        append(0b0100, 4)
        append(bytes.count, version < 10 ? 8 : 16)
        for byte in bytes { append(Int(byte), 8) }
        let capacity = dataCodewords(version) * 8
        append(0, min(4, capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var data: [UInt8] = stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start ..< start + 8].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while data.count < dataCodewords(version) {
            data.append(pad)
            pad ^= 0xEC ^ 0x11
        }

        let blockCount = blocks[version]
        let ecc = eccPerBlock[version]
        let raw = rawCodewords(version)
        let shortBlocks = blockCount - raw % blockCount
        let shortLength = raw / blockCount
        let divisor = reedSolomonDivisor(ecc)
        var dataBlocks: [[UInt8]] = []
        var eccBlocks: [[UInt8]] = []
        var offset = 0
        for index in 0 ..< blockCount {
            let length = shortLength - ecc + (index < shortBlocks ? 0 : 1)
            let block = Array(data[offset ..< offset + length])
            offset += length
            dataBlocks.append(block)
            eccBlocks.append(reedSolomonRemainder(block, divisor))
        }
        var result: [UInt8] = []
        for index in 0 ..< (dataBlocks.map(\.count).max() ?? 0) {
            for block in dataBlocks where index < block.count { result.append(block[index]) }
        }
        for index in 0 ..< ecc {
            for block in eccBlocks { result.append(block[index]) }
        }
        return result
    }

    static func reedSolomonDivisor(_ degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0 ..< degree {
            for index in 0 ..< degree {
                result[index] = multiply(result[index], root)
                if index + 1 < degree { result[index] ^= result[index + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    static func reedSolomonRemainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for index in 0 ..< divisor.count { result[index] ^= multiply(divisor[index], factor) }
        }
        return result
    }

    /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for shift in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> shift) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }

    // MARK: Drawing

    private struct Builder {
        let version: Int
        let size: Int
        var modules: [Bool]
        var function: [Bool]

        init(version: Int) {
            self.version = version
            size = version * 4 + 17
            modules = Array(repeating: false, count: size * size)
            function = Array(repeating: false, count: size * size)
        }

        mutating func set(_ x: Int, _ y: Int, _ dark: Bool) {
            modules[y * size + x] = dark
            function[y * size + x] = true
        }

        func dark(_ x: Int, _ y: Int) -> Bool { modules[y * size + x] }

        mutating func drawFunctionPatterns() {
            for index in 0 ..< size {
                set(6, index, index % 2 == 0)
                set(index, 6, index % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)
            let positions = QRCode.alignment[version]
            for (i, x) in positions.enumerated() {
                for (j, y) in positions.enumerated() {
                    let last = positions.count - 1
                    if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) { continue }
                    for dy in -2 ... 2 {
                        for dx in -2 ... 2 { set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1) }
                    }
                }
            }
            drawFormatBits(mask: 0)
            drawVersion()
        }

        private mutating func drawFinder(_ x: Int, _ y: Int) {
            for dy in -4 ... 4 {
                for dx in -4 ... 4 {
                    let distance = max(abs(dx), abs(dy))
                    let (column, row) = (x + dx, y + dy)
                    if column >= 0, column < size, row >= 0, row < size {
                        set(column, row, distance != 2 && distance != 4)
                    }
                }
            }
        }

        mutating func drawFormatBits(mask: Int) {
            let data = 0 << 3 | mask
            var remainder = data
            for _ in 0 ..< 10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = (data << 10 | remainder) ^ 0x5412
            func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }
            for index in 0 ... 5 { set(8, index, bit(index)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for index in 9 ..< 15 { set(14 - index, 8, bit(index)) }
            for index in 0 ..< 8 { set(size - 1 - index, 8, bit(index)) }
            for index in 8 ..< 15 { set(8, size - 15 + index, bit(index)) }
            set(8, size - 8, true)
        }

        private mutating func drawVersion() {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0 ..< 12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for index in 0 ..< 18 {
                let dark = (bits >> index) & 1 == 1
                let a = size - 11 + index % 3
                let b = index / 3
                set(a, b, dark)
                set(b, a, dark)
            }
        }

        mutating func drawCodewords(_ data: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0 ..< size {
                    for offset in 0 ..< 2 {
                        let x = right - offset
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        guard !function[y * size + x], index < data.count * 8 else { continue }
                        modules[y * size + x] = (data[index >> 3] >> (7 - index & 7)) & 1 == 1
                        index += 1
                    }
                }
                right -= 2
            }
        }

        /// XORs the mask onto data modules; applying it twice undoes it.
        mutating func applyMask(_ mask: Int) {
            for y in 0 ..< size {
                for x in 0 ..< size where !function[y * size + x] {
                    let invert = switch mask {
                    case 0: (x + y) % 2 == 0
                    case 1: y % 2 == 0
                    case 2: x % 3 == 0
                    case 3: (x + y) % 3 == 0
                    case 4: (x / 3 + y / 2) % 2 == 0
                    case 5: x * y % 2 + x * y % 3 == 0
                    case 6: (x * y % 2 + x * y % 3) % 2 == 0
                    default: ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[y * size + x].toggle() }
                }
            }
        }

        func penalty() -> Int {
            var result = 0
            for line in 0 ..< size {
                result += linePenalty { dark($0, line) }
                result += linePenalty { dark(line, $0) }
            }
            for y in 0 ..< size - 1 {
                for x in 0 ..< size - 1 {
                    let color = dark(x, y)
                    if color == dark(x + 1, y), color == dark(x, y + 1), color == dark(x + 1, y + 1) { result += 3 }
                }
            }
            let darkCount = modules.filter { $0 }.count
            let total = size * size
            let k = (abs(darkCount * 20 - total * 10) + total - 1) / total - 1
            return result + k * 10
        }

        /// Runs of one color and finder-like patterns along one row or column.
        private func linePenalty(_ module: (Int) -> Bool) -> Int {
            var result = 0
            var color = false
            var run = 0
            var history = [Int](repeating: 0, count: 7)
            for index in 0 ..< size {
                if module(index) == color {
                    run += 1
                    if run == 5 { result += 3 } else if run > 5 { result += 1 }
                } else {
                    addHistory(run, &history)
                    if !color { result += countPatterns(history) * 40 }
                    color = module(index)
                    run = 1
                }
            }
            if color {
                addHistory(run, &history)
                run = 0
            }
            addHistory(run + size, &history)
            return result + countPatterns(history) * 40
        }

        private func addHistory(_ length: Int, _ history: inout [Int]) {
            let length = history[0] == 0 ? length + size : length
            history.removeLast()
            history.insert(length, at: 0)
        }

        private func countPatterns(_ history: [Int]) -> Int {
            let n = history[1]
            let core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
            return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0)
                + (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0)
        }
    }
}
