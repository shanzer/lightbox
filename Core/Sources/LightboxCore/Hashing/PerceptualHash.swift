import Foundation

/// A DCT perceptual hash, ported from photolib's `lib/phash.js`.
///
/// Every constant here is part of the hash's definition. Changing any of them
/// silently invalidates every hash either tool has ever stored, which is why
/// the identifier is recorded alongside the value.
public struct PerceptualHash: Sendable, Hashable {
    public static let identifier = "phash-dct-64-nodc"
    public static let gridSize = 32

    private static let block = 8
    /// Six decimal places: far above the ~1e-10 floating-point noise floor at
    /// these coefficient magnitudes, far below any real difference between
    /// distinct images. A determinism guard, not a tuning knob.
    private static let quantum = 1_000_000.0

    /// Basis functions, indexed `[u * gridSize + x]`.
    private static let cosineTable: [Double] = {
        let n = gridSize
        var table = [Double](repeating: 0, count: n * n)
        for u in 0..<n {
            let scale = u == 0 ? (1.0 / Double(n)).squareRoot() : (2.0 / Double(n)).squareRoot()
            for x in 0..<n {
                table[u * n + x] = scale * cos((2 * Double(x) + 1) * Double(u) * .pi / (2 * Double(n)))
            }
        }
        return table
    }()

    public let value: UInt64

    public var hex: String {
        let alphabet = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(16)
        for shift in stride(from: 60, through: 0, by: -4) {
            out.append(alphabet[Int((value >> UInt64(shift)) & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public init(gray: [UInt8]) throws {
        let n = Self.gridSize
        guard gray.count == n * n else {
            throw HashError.malformed("phash expects a \(n)x\(n) grid, got \(gray.count) samples")
        }

        let coefficients = Self.dct2(gray)

        var picked = [Double](repeating: 0, count: 64)
        var index = 0
        for v in 0..<Self.block {
            for u in 0..<Self.block {
                if v == 0 && u == 0 { continue }        // DC: overall brightness only
                picked[index] = (coefficients[v * n + u] * Self.quantum).rounded() / Self.quantum
                index += 1
            }
        }
        // F(0,8), replacing the discarded DC term to keep 64 informative bits.
        picked[index] = (coefficients[Self.block] * Self.quantum).rounded() / Self.quantum

        let sorted = picked.sorted()
        let median = (sorted[31] + sorted[32]) / 2

        var bits: UInt64 = 0
        for i in 0..<64 where picked[i] > median {
            bits |= UInt64(1) << UInt64(63 - i)
        }
        value = bits
    }

    public init(hex: String) throws {
        guard hex.count == 16, hex.allSatisfy({ $0.isHexDigit }),
              let parsed = UInt64(hex, radix: 16) else {
            throw HashError.malformed("not a 64-bit hash: \(hex)")
        }
        value = parsed
    }

    public init(value: UInt64) { self.value = value }

    public func distance(to other: PerceptualHash) -> Int {
        (value ^ other.value).nonzeroBitCount
    }

    /// Separable two-dimensional DCT-II, coefficients indexed `[v * n + u]`.
    private static func dct2(_ gray: [UInt8]) -> [Double] {
        let n = gridSize
        var intermediate = [Double](repeating: 0, count: n * n)
        for y in 0..<n {
            for u in 0..<n {
                var sum = 0.0
                for x in 0..<n { sum += cosineTable[u * n + x] * Double(gray[y * n + x]) }
                intermediate[y * n + u] = sum
            }
        }
        var out = [Double](repeating: 0, count: n * n)
        for u in 0..<n {
            for v in 0..<n {
                var sum = 0.0
                for y in 0..<n { sum += cosineTable[v * n + y] * intermediate[y * n + u] }
                out[v * n + u] = sum
            }
        }
        return out
    }
}
