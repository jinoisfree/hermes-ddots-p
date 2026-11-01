import Foundation

@main
struct WritingShimmerTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func spinnerContracts() {
        // Spinner T-01: reference-video clockwise cells and the six lit sets are independent literals.
        let lit: [Set<Int>] = [[0,5,4,3], [1,0,5,4], [2,1,0,5], [3,2,1,0], [4,3,2,1], [5,4,3,2]]
        for head in 0..<6 {
            let time = (Double(head) + 0.5) * WritingSpinner.stepDuration
            let levels = WritingSpinner.levels(at: time, reduceMotion: false)
            check(levels.count == 6, "spinner T-01 has six levels")
            check(Set(levels.indices.filter { levels[$0] > 0 }) == lit[head], "spinner T-01 step \(head) lights exactly the reference four-dot tail")
            let ordered = (0..<4).map { levels[(head - $0 + 6) % 6] }
            check(ordered[0] == 1 && zip(ordered, ordered.dropFirst()).allSatisfy { $0 > $1 } && ordered[3] > 0,
                  "spinner T-01 head is brightest and the tail strictly fades")
            check(levels.indices.filter { !lit[head].contains($0) }.allSatisfy { levels[$0] == 0 }, "spinner T-01 other two dots are off")
            check(WritingSpinner.levels(at: time + 6 * WritingSpinner.stepDuration, reduceMotion: false) == levels,
                  "spinner T-01 repeats after six steps")
        }
        check((0.14...0.18).contains(WritingSpinner.stepDuration), "spinner T-01 step duration stays in range")
        let expectedCells: [WritingSpinner.Position] = [
            .init(column: 0, row: 0), .init(column: 1, row: 0), .init(column: 1, row: 1),
            .init(column: 1, row: 2), .init(column: 0, row: 2), .init(column: 0, row: 1)
        ]
        check(WritingSpinner.positions == expectedCells, "spinner T-01 positions trace the clockwise ring")
        // Spinner T-02: the fixed L is specified independently, including zero levels.
        for time in [-1.0, 0.0, 0.08, 0.24, 0.8, 1.0, 7200, 815_000_000] {
            check(WritingSpinner.levels(at: time, reduceMotion: true) == [1, 0, 0, 0.35, 0.5, 0.7], "spinner T-02 reduce motion fixes head zero")
        }
        print("WritingSpinnerTests: T-01, T-02 passed")
    }
    static func main() {
        // T-01: motion direction, offscreen endpoints and repeat are observable contracts.
        check((1.4...2.2).contains(WritingShimmer.period), "period stays in the approved range")
        let times = stride(from: 0.0, through: 1.79, by: 0.01)
        let positions = times.map { WritingShimmer.phase(at: $0, reduceMotion: false)! }
        check(positions.first! < 0 && positions.last! > 1, "band starts left and finishes right of text")
        check(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }, "band moves strictly left to right")
        for time in [0.0, 0.3, 0.9, 1.6, -0.3] {
            let a = WritingShimmer.phase(at: time, reduceMotion: false)!
            let b = WritingShimmer.phase(at: time + WritingShimmer.period, reduceMotion: false)!
            check(abs(a - b) < 1e-12, "one period repeats the same position")
        }
        // T-02: reducing motion removes the band at every point, including the wrap.
        for time in [0.0, 0.3, 0.9, 1.79, 1.8, 7200] {
            check(WritingShimmer.phase(at: time, reduceMotion: true) == nil, "reduce motion draws no band")
        }
        print("WritingShimmerTests: T-01, T-02 passed")
        spinnerContracts()
    }
}
