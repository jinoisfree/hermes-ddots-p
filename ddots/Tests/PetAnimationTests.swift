import Foundation
import CoreGraphics

@main
struct PetAnimationTests {
    static func main() {
        precondition(PetChatPlayback.animation(state:.waiting,typing:true,jumping:true,drag:nil,preview:nil) == .waiting)
        precondition(PetChatPlayback.animation(state:.failed,typing:true,jumping:true,drag:nil,preview:nil) == .failed)
        precondition(PetChatPlayback.animation(state:.running,typing:true,jumping:false,drag:nil,preview:nil) == .replyWaiting)
        precondition(PetChatPlayback.animation(state:.running,typing:true,jumping:true,drag:nil,preview:nil) == .jumping)
        precondition(PetChatPlayback.animation(state:.waiting,typing:true,jumping:true,drag:.left,preview:nil) == .left)
        precondition(PetChatPlayback.animation(state:.waiting,typing:true,jumping:true,drag:.left,preview:.waving) == .waving)
        var playback = PetChatPlayback()
        precondition(playback.update(now:0,reply:true,pointerElapsed:nil,enabled:true) == 0)
        precondition(playback.update(now:0.4,reply:true,pointerElapsed:0,enabled:true) == 0.4, "Overlapping reply and pointer jumps do not restart")
        precondition(playback.update(now:0.85,reply:false,pointerElapsed:0.45,enabled:true) == nil, "Exactly one jump cycle")
        precondition(playback.update(now:1,reply:true,pointerElapsed:nil,enabled:false) == nil, "Urgent/drag/preview suppress a reply jump")
        for action in [PetAnimation.replyWaiting,.jumping] {
            precondition(PetAnimationTimeline.frame(for:action,elapsed:0.4,reducedMotion:true,loop:true) == PetAnimationFrame(row:action.rawValue,column:0))
        }
        precondition(PetAnimationTimeline.frame(for:.replyWaiting,elapsed:50,loop:true).row == 8)
        for (action, count) in [(PetAnimation.waiting, 8), (.replyWaiting, 6)] {
            let frames = stride(from: 50.0, to: 53.0, by: 0.06).map { PetAnimationTimeline.frame(for: action, elapsed: $0) }
            precondition(frames.allSatisfy { $0.row == action.rawValue }, "Approval and computer waits never return to idle while active")
            precondition(Set(frames.map(\.column)).count == count, "Every frame keeps playing after fifty seconds")
        }
        precondition(PetChatPlayback.animation(state:.idle,typing:false,jumping:false,drag:nil,preview:nil) == .idle, "Finished waits return to the default pose")
        precondition(PetChatPlayback.animation(state:.running,typing:false,jumping:false,drag:nil,preview:nil) == .running, "Ordinary work is not mistaken for an external reply wait")
        print("PASS: chat priority, shared one-shot jump, continuous approval/computer loops and reduced-motion frames")
        let origin = CGPoint(x: -1200, y: 200)
        for index in 0..<16 {
            let angle = Double(index) * .pi / 8
            let target = CGPoint(x: origin.x + sin(angle) * 100, y: origin.y + cos(angle) * 100)
            precondition(PetAnimationTimeline.lookFrame(from: origin, toward: target) ==
                         PetAnimationFrame(row: 9 + index / 8, column: index % 8), "16방향 및 다중 모니터 좌표")
        }
        precondition(PetAnimationTimeline.lookFrame(from: origin, toward: origin) == nil)
        precondition(PetAnimationTimeline.lookFrame(from: .zero, toward: CGPoint(x: CGFloat.nan, y: 0)) == nil)
        let up = PetAnimationFrame(row: 9, column: 0)
        let next = PetAnimationFrame(row: 9, column: 1)
        func direction(_ degrees: Double) -> CGPoint { CGPoint(x: sin(degrees * .pi / 180) * 100, y: cos(degrees * .pi / 180) * 100) }
        precondition(PetAnimationTimeline.lookFrame(from: .zero, toward: direction(12), previous: up) == up, "direction boundary noise does not flicker")
        precondition(PetAnimationTimeline.lookFrame(from: .zero, toward: direction(14), previous: up) == next, "intentional direction change still follows cursor")
        precondition(PetAnimationTimeline.lookFrame(from: .zero, toward: direction(11), previous: next) == next, "reverse boundary has the same margin")
        precondition(PetAnimationTimeline.lookFrame(from: .zero, toward: direction(348), previous: up) == up, "angular margin wraps across zero")
        precondition(PetAnimationTimeline.lookFrame(from: .zero, toward: .zero, previous: next) == next, "center dead zone retains last look instead of popping to idle")
        precondition(PetAnimationTimeline.dragAnimation(horizontalDelta: -3) == .left)
        precondition(PetAnimationTimeline.dragAnimation(horizontalDelta: 3) == .right)
        precondition(PetAnimationTimeline.dragAnimation(horizontalDelta: 0, previous: .left) == .left)
        precondition(PetAnimationTimeline.frame(for: .running, elapsed: 0.13).column == 1)
        precondition(PetAnimationTimeline.frame(for: .running, elapsed: 0.7).column == 5)
        precondition(PetAnimationTimeline.frame(for: .running, elapsed: 2.47).row == 0, "세 번 재생 후 대기로 복귀")
        precondition(PetAnimationTimeline.frame(for: .left, elapsed: 4, loop: true).row == 2, "드래그 중 방향 유지")
        precondition(PetAnimationTimeline.frame(for: .idle, elapsed: 1.67).column == 0)
        precondition(PetAnimationTimeline.frame(for: .idle, elapsed: 1.69).column == 1)
        for animation in PetAnimation.allCases {
            precondition(PetAnimationTimeline.frame(for: animation, elapsed: 30, reducedMotion: true) ==
                         PetAnimationFrame(row: animation.rawValue, column: 0), "동작 줄이기 준수")
            for time in stride(from: 0.0, to: 30, by: 0.05) {
                let frame = PetAnimationTimeline.frame(for: animation, elapsed: time)
                precondition((0..<9).contains(frame.row) && (0..<8).contains(frame.column), "유효한 스프라이트 셀")
            }
        }
        precondition(!PetAnimation.waiting.allowsLook && !PetAnimation.failed.allowsLook)
        // The pet inside the conversation: one thing at a time, the liveliest first.
        var inside = ChatPetBehavior()
        _ = inside.update(now: 0, touching: false, cursorNear: false, writing: false, hop: false, wave: false)
        precondition(inside.pose == .idle, "아무 일 없으면 쉰다")
        _ = inside.update(now: 1, touching: false, cursorNear: true, writing: false, hop: false, wave: false)
        precondition(inside.pose == .look, "커서가 대화 위에 있으면 본다")
        _ = inside.update(now: 2, touching: false, cursorNear: true, writing: false, hop: false, wave: true)
        precondition(inside.pose == .wave, "보낼 때 한 번 손을 흔든다")
        precondition(inside.update(now: 2.5, touching: false, cursorNear: true, writing: false, hop: false, wave: false) == 0.5 && inside.pose == .wave)
        _ = inside.update(now: 2 + ChatPetBehavior.waveDuration + 0.01, touching: false, cursorNear: true, writing: false, hop: false, wave: false)
        precondition(inside.pose == .look, "한 번 흔들고 돌아온다")
        _ = inside.update(now: 4, touching: false, cursorNear: true, writing: true, hop: false, wave: false)
        precondition(inside.pose == .replyWaiting, "캐릭터가 쓰는 동안은 컴퓨터를 하며 기다린다")
        _ = inside.update(now: 5, touching: false, cursorNear: true, writing: true, hop: true, wave: false)
        precondition(inside.pose == .jump, "답이 오면 뛴다")
        _ = inside.update(now: 5 + PetChatPlayback.jumpDuration + 0.01, touching: false, cursorNear: false, writing: false, hop: false, wave: false)
        precondition(inside.pose == .idle, "뛰고 나면 쉰다")
        _ = inside.update(now: 7, touching: true, cursorNear: true, writing: false, hop: false, wave: false)
        precondition(inside.pose == .jump, "커서가 닿으면 한 번 뛴다")
        _ = inside.update(now: 9, touching: true, cursorNear: true, writing: false, hop: false, wave: false)
        precondition(inside.pose == .look, "계속 닿아 있어도 다시 뛰지 않는다")
        _ = inside.update(now: 10, touching: true, cursorNear: true, writing: true, hop: true, wave: true, approval: true)
        precondition(inside.pose == .approval, "Approval takes priority over writing, incoming replies and pointer reactions")
        precondition(inside.update(now: 60, touching: false, cursorNear: false, writing: false, hop: false, wave: false, approval: true) == 50 && inside.pose == .approval, "Approval playback does not restart on each tick")
        _ = inside.update(now: 61, touching: false, cursorNear: false, writing: true, hop: false, wave: false)
        precondition(inside.pose == .replyWaiting, "Reply computer resumes after approval is resolved")
        _ = inside.update(now: 62, touching: false, cursorNear: false, writing: false, hop: false, wave: false)
        precondition(inside.pose == .idle, "Resolved requests leave no lingering approval or reply pose")
        // Nodding off: only after three quiet minutes, and anything happening starts the count again.
        var doze = PetDoze()
        precondition(doze.update(now: 10, quiet: true) == nil && doze.update(now: 189.9, quiet: true) == nil, "3분이 되기 전에는 졸지 않는다")
        precondition(doze.update(now: 190.5, quiet: true) == 0.5, "조용한 3분 뒤에 졸기 시작한다")
        precondition(doze.update(now: 200, quiet: false) == nil, "무슨 일이 생기면 깬다")
        precondition(doze.update(now: 201, quiet: true) == nil && doze.update(now: 380, quiet: true) == nil, "깬 뒤에는 3분을 다시 센다")
        precondition(doze.update(now: 381, quiet: true) == 0)
        precondition(doze.update(now: 500, quiet: false) == nil && doze.update(now: 501, quiet: true, after: 1) == nil)
        precondition(doze.update(now: 503, quiet: true, after: 1) == 1, "확인용으로 기다림을 줄일 수 있다")
        let steps = PetAnimationTimeline.dozeSteps
        precondition(steps.map(\.image) == [0, 1, 2, 3, 4, 3, 2, 3, 4, 3, 2, 3, 4, 3, 1], "눈 뜸, 한쪽 감김, 감은 채 세 번 까딱, 번쩍")
        precondition(steps.map(\.zs) == [0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 0], "까딱일 때마다 z가 하나씩 는다")
        precondition(abs(PetAnimationTimeline.dozeCycle - 5.82) < 0.0001)
        let columns = [0, 0.89, 0.91, 1.36, 1.96, 2.16, 2.60, 5.66, 5.68, 5.83].map { PetAnimationTimeline.dozeFrame(elapsed: $0).column }
        precondition(columns == [0, 0, 1, 2, 3, 4, 5, 13, 14, 0], "순서대로 돌고 처음으로 돌아온다")
        precondition(PetAnimationTimeline.dozeFrame(elapsed: 100).row == PetAnimationTimeline.dozeRow)
        precondition(PetAnimationTimeline.dozeFrame(elapsed: 0.3, reducedMotion: true) == PetAnimationFrame(row: 11, column: 10), "동작 줄이기에서는 잠든 한 장면")
        precondition(PetAnimationTimeline.dozeZs(column: 10).count == 3)
        for column in steps.indices {
            let zs = PetAnimationTimeline.dozeZs(column: column)
            precondition(zs.allSatisfy { CGRect(x: 2, y: 2, width: 188, height: 204).contains($0) }, "z는 펫의 칸 안에 그린다")
            precondition(zip(zs, zs.dropFirst()).allSatisfy { $1.width > $0.width && $1.minY < $0.minY && $1.minX > $0.maxX }, "위로 갈수록 커진다")
        }
        precondition(PetAnimationTimeline.dozeZs(column: 99).isEmpty)
        print("PASS: 16 look directions, drag direction, original timing, idle return, reduced motion, nodding off")
    }
}
