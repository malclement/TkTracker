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
        #expect(template.frontSpots.contains(stations[members[2].id]!))
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
        for desks in [1, 2, 3, 4, 5, 7, 9, 12, 16, 25, 36, WorkshopRoomTemplate.maxDesks] {
            let template = WorkshopRoomTemplate(deskCount: desks)
            var stations = (0..<desks).flatMap { [template.seat(desk: $0), template.hover(desk: $0)] }
            stations += template.frontSpots + WorkshopRoomTemplate.coffeeSpots + template.couchSpots + [WorkshopRoomTemplate.whiteboard]
            for station in stations {
                #expect(!template.blocked.contains(station.tile), "\(station) is blocked with \(desks) desks")
                let path = WorkshopPathfinder.path(from: template.door, to: station.tile, blocked: template.blocked, width: template.depth, height: template.length)
                #expect(path.first == template.door && path.last == station.tile)
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
        #expect(WorkshopPathfinder.path(from: .init(i: 0, j: 0), to: .init(i: 2, j: 2), blocked: blocked, width: 7, height: 6) == [.init(i: 0, j: 0), .init(i: 2, j: 2)])
        #expect(WorkshopPathfinder.path(from: .init(i: 1, j: 1), to: .init(i: 1, j: 1), blocked: [], width: 7, height: 6) == [.init(i: 1, j: 1)])
    }

    @Test func desksStayPutAsTeammatesComeAndGo() {
        var desks = WorkshopDeskPlan.assign(previous: [:], ids: ["a", "b", "c"], capacity: 12)
        #expect(desks == ["a": 0, "b": 1, "c": 2])
        desks = WorkshopDeskPlan.assign(previous: desks, ids: ["a", "c", "d"], capacity: 12)
        #expect(desks == ["a": 0, "c": 2, "d": 1])
        #expect(WorkshopDeskPlan.assign(previous: [:], ids: (0..<20).map(String.init), capacity: 12).count == 12)
    }

    @Test func roomsGrowInBothDirectionsWithoutMovingAnyDesk() {
        let one = WorkshopRoomTemplate(deskCount: 1), four = WorkshopRoomTemplate(deskCount: 4), five = WorkshopRoomTemplate(deskCount: 5)
        #expect((one.depth, one.length) == (7, 6))
        #expect((four.depth, four.length) == (7, 8))
        #expect((five.rows, five.bays) == (3, 2))
        #expect(five.depth == 10)
        #expect(WorkshopRoomTemplate(deskCount: 99).deskCount == WorkshopRoomTemplate.maxDesks)
        // The first n desks fill a near-square grid.
        let fifty = WorkshopRoomTemplate(deskCount: 50)
        #expect(abs(fifty.rows - fifty.bays) <= 1)
        // Desk n stands in the same place whatever the room's size.
        let small = WorkshopRoomTemplate(deskCount: 2)
        #expect(small.seat(desk: 1) == fifty.seat(desk: 1))
        // No two desks overlap, and every desk fits inside its room.
        let tiles = fifty.furniture.flatMap(\.tiles)
        #expect(Set(tiles).count == tiles.count)
        #expect(tiles.allSatisfy { $0.i >= 0 && $0.j >= 0 && $0.i < fifty.depth && $0.j < fifty.length })
        #expect(!fifty.blocked.contains(fifty.door))
        // A deep room gets more couches along its side wall.
        #expect(WorkshopRoomTemplate(deskCount: 1).couches == [3])
        #expect(fifty.couches.count > 3)
    }

    @Test func sessionsOnOneProjectShareABuilding() {
        func lead(_ id: String, _ path: String, opened: Double) -> WorkshopAgent {
            var agent = agent(id, .working)
            agent.projectPath = path
            agent.openedAt = Date(timeIntervalSince1970: opened)
            return agent
        }
        let islands = WorkshopIsland.group([lead("a", "/work/app", opened: 1), lead("b", "/work/site", opened: 2),
                                            lead("c", "/work/app", opened: 3), agent("d", .working, parent: "c")])
        let projects = WorkshopProject.group(islands)
        #expect(projects.map(\.path) == ["/work/app", "/work/site"])
        #expect(projects[0].sessions.map(\.lead.sessionID) == ["a", "c"])
        #expect(projects[0].agents.count == 3)
        #expect(projects[0].subagentCount == 1)
    }

    @Test func aWaitingLeadWatchesItsOwnSubagentFirst() {
        let members = [agent("one", .working), agent("two", .waitingForAgents), agent("mine", .working, parent: "two")]
        let template = WorkshopRoomTemplate(deskCount: members.count)
        let stations = WorkshopStationPlanner.stations(for: members, template: template,
                                                       teams: ["one": "one", "two": "two", "mine": "two"])
        #expect(stations[members[1].id] == template.hover(desk: 2))
    }

    @Test func buildingsLineTheStreetAndOnlySideWallsDrop() {
        // Fronts line up on the street; a shallower building has lawn behind it.
        #expect(WorkshopLotPlan.origins(sizes: [(7, 6), (10, 8), (7, 6)]) == [.init(i: 3, j: 0), .init(i: 0, j: 8), .init(i: 3, j: 18)])
        #expect(WorkshopLotPlan.bounds(sizes: [(7, 6), (10, 8)]).1 == .init(i: 10, j: 16))
        #expect(WorkshopLotPlan.wallHeights(index: 0) == (WorkshopLotPlan.fullWall, WorkshopLotPlan.fullWall))
        #expect(WorkshopLotPlan.wallHeights(index: 2) == (WorkshopLotPlan.lowWall, WorkshopLotPlan.fullWall))
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
