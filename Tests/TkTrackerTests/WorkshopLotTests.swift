import Foundation
import Testing
@testable import TkTracker

@Suite("Pixel workshop layout and behaviour")
struct WorkshopLotTests {
    private func agent(_ id: String, _ state: WorkshopState, parent: String? = nil) -> WorkshopAgent {
        WorkshopAgent(id: WorkshopAgent.key(profile: "p", source: .codex, session: id), sessionID: id, profileID: "p", source: .codex,
                      parentSessionID: parent, projectPath: "/work/app", title: id, model: nil, digestPath: nil,
                      state: state, activity: state.label, lastActivity: nil, openedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func toolKindsComeFromTheToolNameOnly() {
        #expect(WorkshopToolKind(toolName: "Grep") == .search)
        #expect(WorkshopToolKind(toolName: "WebFetch") == .search)
        #expect(WorkshopToolKind(toolName: "Read") == .read)
        #expect(WorkshopToolKind(toolName: "apply_patch") == .edit)
        #expect(WorkshopToolKind(toolName: "Edit") == .edit)
        #expect(WorkshopToolKind(toolName: "exec_command") == .run)
        #expect(WorkshopToolKind(toolName: "Bash") == .run)
        #expect(WorkshopToolKind(toolName: "Task") == .delegate)
        #expect(WorkshopToolKind(toolName: "spawn_agent") == .delegate)
        #expect(WorkshopToolKind(toolName: "mcp__linear__create") == .other)
    }

    @Test func readerReportsTheToolAndClearsItOnTheNextState() throws {
        var reader = WorkshopActivityReader()
        let call = try JSONSerialization.data(withJSONObject: ["type": "response_item", "timestamp": "2026-09-25T10:00:00Z",
            "payload": ["type": "function_call", "name": "exec_command", "call_id": "a"]])
        reader.consume(call, source: .codex)
        #expect(reader.state == .usingTool)
        #expect(reader.tool == .run)
        #expect(reader.activity == "Running a tool")
        let done = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": "2026-09-25T10:00:05Z",
            "payload": ["type": "task_complete"]])
        reader.consume(done, source: .codex)
        #expect(reader.state == .completed)
        #expect(reader.tool == nil)
    }

    @Test func eachStateGoesToItsOwnKindOfPlace() {
        let members = [agent("lead", .waitingForAgents), agent("a", .working, parent: "lead"), agent("b", .needsInput, parent: "lead"), agent("c", .completed, parent: "lead")]
        let template = WorkshopRoomTemplate(deskCount: members.count)
        let stations = WorkshopStationPlanner.stations(for: members, template: template)
        #expect(stations[members[1].id] == template.seat(desk: 1))
        #expect(stations[members[2].id]?.pose == .wave)
        #expect(WorkshopRoomTemplate.frontSpots.contains(stations[members[2].id]!))
        #expect(WorkshopRoomTemplate.coffeeSpots.contains(stations[members[3].id]!))
        // The waiting lead watches the one teammate who is working.
        #expect(stations[members[0].id] == template.hover(desk: 1))
    }

    @Test func aLoneIdlerLiesDownAndAGroupSitsUp() {
        let alone = [agent("lead", .idle)]
        #expect(WorkshopStationPlanner.stations(for: alone, template: .init(deskCount: 1))[alone[0].id]?.pose == .sleep)
        let pair = [agent("lead", .idle), agent("a", .idle, parent: "lead")]
        let stations = WorkshopStationPlanner.stations(for: pair, template: .init(deskCount: 2))
        #expect(stations.values.allSatisfy { $0.pose == .sit })
        #expect(Set(stations.values.map(\.tile)).count == 2)
    }

    @Test func stationsNeverStandOnFurnitureAndAreReachableFromTheDoor() {
        for desks in 1...WorkshopRoomTemplate.maxDesks {
            let template = WorkshopRoomTemplate(deskCount: desks)
            var stations = (0..<desks).flatMap { [template.seat(desk: $0), template.hover(desk: $0)] }
            stations += WorkshopRoomTemplate.frontSpots + WorkshopRoomTemplate.coffeeSpots + WorkshopRoomTemplate.couchSpots + [WorkshopRoomTemplate.whiteboard]
            for station in stations {
                #expect(!template.blocked.contains(station.tile), "\(station) is blocked with \(desks) desks")
                let path = WorkshopPathfinder.path(from: WorkshopRoomTemplate.door, to: station.tile, blocked: template.blocked)
                #expect(path.first == WorkshopRoomTemplate.door && path.last == station.tile)
                // Each step moves one tile and never crosses furniture.
                for (a, b) in zip(path, path.dropFirst()) {
                    #expect(abs(a.i - b.i) + abs(a.j - b.j) == 1)
                    #expect(!template.blocked.contains(b))
                }
            }
        }
    }

    @Test func pathfinderFallsBackWhenTheGoalIsBlocked() {
        let blocked: Set<WorkshopTile> = [.init(i: 2, j: 2)]
        #expect(WorkshopPathfinder.path(from: .init(i: 0, j: 0), to: .init(i: 2, j: 2), blocked: blocked) == [.init(i: 0, j: 0), .init(i: 2, j: 2)])
        #expect(WorkshopPathfinder.path(from: .init(i: 1, j: 1), to: .init(i: 1, j: 1), blocked: []) == [.init(i: 1, j: 1)])
    }

    @Test func roomsKeepTheirSlotsAsOthersComeAndGo() {
        var slots = WorkshopLotPlan.assignSlots(previous: [:], ids: ["a", "b", "c"])
        #expect(slots == ["a": 0, "b": 1, "c": 2])
        slots = WorkshopLotPlan.assignSlots(previous: slots, ids: ["a", "c", "d"])
        #expect(slots == ["a": 0, "c": 2, "d": 1])
        #expect(WorkshopLotPlan.assignSlots(previous: [:], ids: ["1", "2", "3", "4", "5"]).count == 4)
    }

    @Test func backWallsDropOnlyWhereAnotherRoomSitsBehind() {
        #expect(WorkshopLotPlan.wallHeights(slot: 0, occupied: [0, 1, 2, 3]) == (WorkshopLotPlan.fullWall, WorkshopLotPlan.fullWall))
        #expect(WorkshopLotPlan.wallHeights(slot: 3, occupied: [0, 1, 2, 3]) == (WorkshopLotPlan.lowWall, WorkshopLotPlan.lowWall))
        #expect(WorkshopLotPlan.wallHeights(slot: 3, occupied: [3]) == (WorkshopLotPlan.fullWall, WorkshopLotPlan.fullWall))
        #expect(WorkshopLotPlan.wallHeights(slot: 1, occupied: [0, 1]) == (WorkshopLotPlan.fullWall, WorkshopLotPlan.lowWall))
    }

    @Test func looksAndDecorAreStableAndVaried() {
        #expect(WorkshopLook(agentID: "codex|p|abc") == WorkshopLook(agentID: "codex|p|abc"))
        let looks = Set((0..<200).map { WorkshopLook(agentID: "session-\($0)").key })
        #expect(looks.count > 150)
        let claude = WorkshopDecor(projectPath: "/work/app", source: .claude)
        let codex = WorkshopDecor(projectPath: "/work/app", source: .codex)
        #expect(claude.wallpaper < WorkshopDecor.wallpapersPerFamily)
        #expect(codex.wallpaper >= WorkshopDecor.wallpapersPerFamily)
        #expect(claude.floor == codex.floor)
    }

    @Test func paperStacksGrowWithTokensAndStayBounded() {
        #expect(WorkshopPaperStack.sheets(tokens: nil) == 0)
        #expect(WorkshopPaperStack.sheets(tokens: 500) == 0)
        let steps = [1_000, 10_000, 100_000, 1_000_000, 10_000_000, 1_000_000_000].map { WorkshopPaperStack.sheets(tokens: $0) }
        #expect(steps == steps.sorted())
        #expect(steps.first == 1)
        #expect(steps.last == 12)
    }
}
