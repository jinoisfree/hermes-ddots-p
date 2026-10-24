import Foundation

@main
struct BubbleRevealTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1
    }
    static func main() {
        var reveal = BubbleReveal()
        check(!reveal.update(now: 0, held: false), "the bubble is put away until something brings it out")
        check(reveal.update(now: 1, held: true) && reveal.update(now: 60, held: true) && !reveal.update(now: 60.01, held: false), "it is out for as long as the pointer is on it and goes when the pointer leaves")
        reveal.alert(now: 10)
        check(reveal.update(now: 12.9, held: false) && !reveal.update(now: 13, held: false), "an alert shows it for three seconds")
        reveal.alert(now: 20)
        check(reveal.update(now: 20.5, held: true) && reveal.update(now: 22.9, held: false) && !reveal.update(now: 23, held: false), "a touch during an alert does not cut it short")
        check(reveal.update(now: 25, held: true) && !reveal.update(now: 25.1, held: false), "held past an alert, it goes when the pointer leaves")
        print("BubbleRevealTests: \(passed) checks passed")
    }
}
