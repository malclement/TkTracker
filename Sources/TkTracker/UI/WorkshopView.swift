import SwiftUI
import AppKit

extension WorkshopState {
    var tint: Color { Color(nsColor: ink) }
    var ink: NSColor {
        let pair: (UInt32, UInt32)
        switch self {
        case .working, .usingTool: pair = (0x167463, 0x77CBB4)
        case .needsInput: pair = (0x92551D, 0xE4B166)
        case .waitingForAgents: pair = (0x7560AD, 0xBBA7E4)
        case .completed: pair = (0x377842, 0x8ACB92)
        case .interrupted: pair = (0xA34C46, 0xE3A09A)
        case .idle, .unavailable: return .secondaryLabelColor
        }
        return NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.1 : pair.0)
        }
    }
}

struct WorkshopView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: String?
    @State private var project = ""
    @State private var page = 0
    @State private var zoomStep = 0
    @State private var following = true
    @State private var cameraReset = 0
    @State private var demo = false
    @State private var demoStep = 0
    @State private var demoDate = Date()
    @State private var showingInfo = false
    @State private var detail: FileDigest?

    init(demo: Bool = false) { _demo = State(initialValue: demo) }

    private var agents: [WorkshopAgent] {
        let all = demo ? WorkshopDemo.agents(step: demoStep, now: demoDate) : store.workshops.agents
        return all.filter { demo || store.visibleSources.contains($0.source) }
    }
    private var islands: [WorkshopIsland] {
        WorkshopIsland.group(agents).filter { project.isEmpty || $0.lead.projectPath == project }
    }
    /// One workshop per project; its sessions share the building.
    private var projectGroups: [WorkshopProject] { WorkshopProject.group(islands) }
    private static let perPage = WorkshopLotPlan.maxBuildings
    private var pages: Int { max(1, (projectGroups.count + Self.perPage - 1) / Self.perPage) }
    private var selected: WorkshopAgent? {
        islands.flatMap(\.agents).first { $0.id == selectedID } ?? islands.first?.lead
    }
    private var selectedIsland: WorkshopIsland? { islands.first { $0.agents.contains { $0.id == selected?.id } } }
    private var selectedProject: WorkshopProject? { projectGroups.first { $0.path == selected?.projectPath } }
    private var visibleProjects: [WorkshopProject] {
        if following, let selectedProject { return [selectedProject] }
        return Array(projectGroups.dropFirst(min(page, pages - 1) * Self.perPage).prefix(Self.perPage))
    }
    private var projects: [String] { Array(Set(agents.map(\.projectPath))).sorted() }
    private var needsInput: [WorkshopAgent] { islands.flatMap(\.agents).filter { $0.state == .needsInput } }
    private var chrome: Color { Color(nsColor: NSColor(hex: colorScheme == .dark ? 0x171F2D : 0xF6F7FB)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !needsInput.isEmpty { attentionStrip }
            HStack(spacing: 0) {
                scene
                if !islands.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        sessionRoster
                        if let selected {
                            Divider()
                            inspector(selected)
                        }
                    }.frame(width: 270).background(chrome)
                }
            }
            footer
        }
        .background(chrome)
        .navigationTitle("Workshops")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    if store.showsSourceScope && !demo { SourceScopePicker() }
                    Toggle("Demo", isOn: $demo).toggleStyle(.switch).controlSize(.small)
                        .help("Explore sample rooms and session lifecycle events")
                    Button { showingInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About session activity")
                        .popover(isPresented: $showingInfo) { observationInfo }
                }
            }
        }
        .task(id: demo) {
            guard !demo else { return }
            while !Task.isCancelled {
                let profiles = store.profiles.filter { $0.enabled && store.trackedSources.contains($0.source) }
                await store.workshops.refresh(profiles: profiles, digests: store.allDigests, keepsTitles: !store.privacyPolicy.omitTitles)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: demo) { _, _ in
            selectedID = nil; project = ""; page = 0; zoomStep = 0; following = true; demoStep = 0; demoDate = Date()
        }
        .onChange(of: project) { _, _ in page = 0; selectedID = nil }
        .onChange(of: agents.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            if !projects.contains(project) { project = "" }
            page = min(page, pages - 1)
        }
        .sheet(item: $detail) { digest in SessionDetailView(digest: digest, allDigests: store.allDigests) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Workshops").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Your agents, at a glance.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if projects.count > 1 {
                Picker("Project", selection: $project) {
                    Text("All projects").tag("")
                    ForEach(projects, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                    }
                }.labelsHidden().frame(maxWidth: 180)
            }
            Label(demo ? "Demo · sample sessions" : "Live on this Mac", systemImage: demo ? "play.rectangle" : "dot.radiowaves.left.and.right")
                .font(.caption.weight(.medium)).foregroundStyle(demo ? Color.orange : Color.secondary)
        }.padding(.horizontal, 22).padding(.vertical, 17)
    }

    private var scene: some View {
        ZStack {
            PixelWorkshop(projects: visibleProjects, selectedID: selected?.id, zoomStep: zoomStep, cameraReset: cameraReset,
                presentationID: following ? "follow/" + (selectedProject?.id ?? "empty") : "overview/\(page)",
                reducedMotion: reducedMotion, dark: colorScheme == .dark, tokens: tokens, onSelect: select)
            if islands.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "house").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(store.workshops.hasLoaded || demo ? "The lot is quiet" : "Looking for your agents…")
                        .font(.title3.weight(.medium))
                    Text("Open a Claude Code or Codex session\nand its workshop will appear here.")
                        .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                    if !demo { Button("Explore a demo") { demo = true }.padding(.top, 5) }
                }.padding(24)
            }
            VStack {
                HStack(alignment: .top) {
                    if !islands.isEmpty { sceneTitle }
                    Spacer()
                    Button {
                        following.toggle(); zoomStep = 0; cameraReset += 1
                    } label: {
                        Label(following ? "Whole lot" : "Follow session", systemImage: following ? "square.grid.2x2" : "scope")
                    }.controlSize(.small).disabled(islands.isEmpty)
                    if demo {
                        Button { demoStep += 1 } label: { Label("Next event", systemImage: "forward.end") }
                            .controlSize(.small)
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if !islands.isEmpty { household }
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        Button { zoomStep = max(-2, zoomStep - 1) } label: { Image(systemName: "minus.magnifyingglass") }
                            .accessibilityLabel("Zoom out").disabled(zoomStep <= -2)
                        Button("Fit") { zoomStep = 0; cameraReset += 1 }.font(.caption)
                            .help("Fit the lot to the window. Drag the scene to pan.")
                        Button { zoomStep = min(3, zoomStep + 1) } label: { Image(systemName: "plus.magnifyingglass") }
                            .accessibilityLabel("Zoom in").disabled(zoomStep >= 3)
                    }.buttonStyle(.borderless).padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(16)
        }.clipped().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the scene is showing, on a panel so it stays legible over the lawn.
    private var sceneTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(following ? (selectedProject?.name ?? "Your lot") : "Whole lot")
                .font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1)
            if following, let agent = selected {
                HStack(spacing: 6) {
                    Label(agent.state.label, systemImage: agent.state.symbol)
                        .foregroundStyle(agent.state.tint)
                    if let project = selectedProject, project.sessions.count > 1 {
                        Text("· \(project.sessions.count) sessions").foregroundStyle(.secondary)
                    }
                }.font(.caption.weight(.medium))
            } else {
                Text(Self.count(projectGroups.count, "project") + " · " + Self.count(islands.count, "session") + " · "
                     + Self.count(islands.flatMap(\.subagents).count, "subagent"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if demo {
                Text(WorkshopDemo.caption(step: demoStep)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .frame(maxWidth: 280, alignment: .leading)
    }
    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// Recorded tokens per agent, for the paper stacks on each desk.
    private var tokens: [String: Int] {
        let shown = visibleProjects.flatMap(\.agents)
        if demo { return WorkshopDemo.tokens(for: shown) }
        let byPath = Dictionary(store.allDigests.map { ($0.path, $0.totals.total) }, uniquingKeysWith: { a, _ in a })
        var result: [String: Int] = [:]
        for agent in shown { if let path = agent.digestPath, let total = byPath[path] { result[agent.id] = Int(total) } }
        return result
    }

    private static let householdLimit = 10

    /// The Sims household panel: everyone on screen, ringed in their state colour.
    private var household: some View {
        let everyone = visibleProjects.flatMap(\.agents)
        return HStack(spacing: 7) {
            ForEach(Array(everyone.prefix(Self.householdLimit))) { agent in
                Button { select(agent.id) } label: {
                    WorkshopPortrait(agent: agent, size: 34)
                        .overlay(alignment: .topTrailing) {
                            if agent.state == .needsInput {
                                Image(systemName: "exclamationmark").font(.system(size: 8, weight: .black))
                                    .foregroundStyle(.black).frame(width: 13, height: 13)
                                    .background(Circle().fill(Color(nsColor: NSColor(hex: 0xFFB13B))))
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .scaleEffect(agent.id == selected?.id ? 1.08 : 1)
                }
                .buttonStyle(.plain)
                .help("\(agent.parentSessionID == nil ? agent.projectName : agent.title) · \(agent.state.label)")
                .accessibilityLabel("\(agent.parentSessionID == nil ? agent.projectName : agent.title), \(agent.state.label)")
            }
            if everyone.count > Self.householdLimit {
                Text("+\(everyone.count - Self.householdLimit)").font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary).padding(.horizontal, 4)
                    .help("\(everyone.count - Self.householdLimit) more in the session list")
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
    }

    private var attentionStrip: some View {
        HStack(spacing: 12) {
            Label("Needs you", systemImage: "hand.raised.fill").font(.caption.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(needsInput) { agent in
                        Button { select(agent.id) } label: {
                            Text("\(agent.projectName) · \(agent.title)").lineLimit(1).frame(maxWidth: 260)
                        }.controlSize(.small)
                    }
                }
            }
        }.padding(.horizontal, 22).padding(.vertical, 9)
            .background(Color.orange.opacity(0.09))
    }

    private var footer: some View {
        HStack(spacing: 15) {
            Label("\(islands.flatMap(\.agents).filter { $0.state.isWorking }.count) working", systemImage: "sparkles")
            if !needsInput.isEmpty {
                Label("\(needsInput.count) \(needsInput.count == 1 ? "needs" : "need") you", systemImage: WorkshopState.needsInput.symbol)
                    .foregroundStyle(WorkshopState.needsInput.tint)
            }
            Label("\(islands.flatMap(\.agents).filter { $0.state == .idle || $0.state == .completed }.count) resting", systemImage: "moon")
            if !demo && store.workshops.hasUncertainty {
                Button { showingInfo = true } label: { Label("Some status unavailable", systemImage: "questionmark.circle") }.buttonStyle(.plain)
            }
            Spacer()
            if pages > 1 && !following {
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).accessibilityLabel("Previous workshops")
                Text("\(page + 1) / \(pages)").monospacedDigit()
                Button { page = min(pages - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= pages - 1).accessibilityLabel("Next workshops")
            } else {
                Label("Local & private", systemImage: "lock")
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 11)
    }

    private var sessionRoster: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OPEN SESSIONS").font(.caption2.weight(.semibold)).tracking(1.3)
                Spacer()
                Text("\(islands.count)").font(.caption.monospacedDigit())
            }.foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 16)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(projectGroups) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            if project.sessions.count > 1 {
                                projectHeader(project)
                                ForEach(project.sessions) { session in sessionRows(session, role: .session) }
                            } else {
                                sessionRows(project.sessions[0], role: .project)
                            }
                        }
                        .padding(5)
                        .background(project.id == selectedProject?.id ? Color.accentColor.opacity(0.08) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }.frame(maxHeight: 300)
        }
    }

    private enum RosterRole { case project, session, subagent }

    /// A project with several sessions: its name, then one row per session.
    private func projectHeader(_ project: WorkshopProject) -> some View {
        Button { select(project.lead.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "building.2").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 28)
                Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.count(project.sessions.count, "session")).font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 7).padding(.top, 5).padding(.bottom, 2).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(project.name), \(Self.count(project.sessions.count, "session"))")
    }

    /// A session's row, and its subagents while it is the selected one.
    @ViewBuilder
    private func sessionRows(_ session: WorkshopIsland, role: RosterRole) -> some View {
        rosterButton(session.lead, role: role, hiddenSubagents: session.id == selectedIsland?.id ? 0 : session.subagents.count)
        if session.id == selectedIsland?.id {
            ForEach(session.subagents) { agent in rosterButton(agent, role: .subagent) }
        }
    }

    private func rosterButton(_ agent: WorkshopAgent, role: RosterRole, hiddenSubagents: Int = 0) -> some View {
        Button { select(agent.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                WorkshopPortrait(agent: agent, size: role == .project ? 28 : role == .session ? 24 : 20)
                    .padding(.leading, role == .subagent ? 22 : role == .session ? 2 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(role == .project ? agent.projectName : agent.title)
                        .font(.system(size: 12, weight: role == .subagent ? .medium : .semibold)).lineLimit(1)
                    if role == .project { Text(agent.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 6) {
                        Label(agent.state.label, systemImage: agent.state.symbol)
                            .foregroundStyle(agent.state.tint)
                        if hiddenSubagents > 0 {
                            Text("· " + Self.count(hiddenSubagents, "subagent")).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected?.id == agent.id {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
            }.padding(7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(role == .project ? agent.projectName : agent.title), \(agent.state.label)")
    }

    private func inspector(_ agent: WorkshopAgent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(agent.parentSessionID == nil ? "SESSION" : "SUBAGENT").font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: agent.source == .codex ? "terminal" : "sparkle").foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: 12) {
                    WorkshopPortrait(agent: agent, size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(agent.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(agent.projectName + " · " + agent.source.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(agent.state.label, systemImage: agent.state.symbol).font(.callout.weight(.medium)).foregroundStyle(agent.state.tint)
                    if agent.activity != agent.state.label {
                        Text(agent.activity).font(.callout).foregroundStyle(.secondary)
                    }
                    if let date = agent.lastActivity {
                        TimelineView(.periodic(from: .now, by: 10)) { _ in
                            (Text("Last activity ") + Text(date, style: .relative) + Text(" ago"))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(agent.state.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                if let model = agent.model {
                    detailRow("Model", value: ModelIdentity.displayName(model))
                }
                detailRow("Session", value: String(agent.sessionID.prefix(8)))
                if let island = selectedIsland, island.agents.count > 1 {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Team").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(island.agents) { member in
                                Button { select(member.id) } label: { WorkshopPortrait(agent: member, size: 26) }
                                    .buttonStyle(.plain)
                                    .help("\(member.title) · \(member.state.label)")
                                    .accessibilityLabel("\(member.title), \(member.state.label)")
                            }
                        }
                    }
                }
                if let digest = store.allDigests.first(where: { $0.path == agent.digestPath }), !demo {
                    detailRow("Recorded tokens", value: Format.tokens(digest.totals.total))
                    Button("Session history…") { detail = digest }.controlSize(.small)
                }
                if !agent.events.isEmpty {
                    Divider()
                    Text("Recent activity").font(.callout.weight(.semibold))
                    ForEach(agent.events.reversed()) { event in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: event.state.symbol).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.label).fixedSize(horizontal: false, vertical: true)
                                Text(event.date, style: .time).foregroundStyle(.tertiary)
                            }
                        }.font(.caption)
                    }
                }
            }.padding(18)
        }.background(chrome)
    }
    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption)
    }
    private func select(_ id: String) {
        if let index = projectGroups.firstIndex(where: { $0.agents.contains(where: { $0.id == id }) }) { page = index / Self.perPage }
        selectedID = id
        following = true; zoomStep = 0
    }
    private var observationInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A workshop for each project").font(.headline)
            Text("Every open session on a project works in the same building, which grows as teams do. Sessions stay while they are loaded, even when agents are idle or a turn is complete. Closing a session removes its team after the next successful checks.")
            Text("Codex may keep a session loaded after its tab closes. Its room empties when Codex releases the session. Claude Code sessions are matched to their running process.")
            Text("Activity comes from local session events. Missing or unreadable signals show an unavailable status. Waiting for you is shown only when an explicit input or approval request is observed.")
            Divider()
            Text("Above each agent").font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(Self.legend, id: \.self) { state in
                    GridRow {
                        Image(decorative: PixelLegend.plumbob(state), scale: 1).interpolation(.none)
                            .resizable().frame(width: 13.5, height: 21)
                        Text(state == .working ? "Working or using a tool" : state.label)
                    }
                }
            }.font(.caption)
            Text("No prompts or tool output are copied into the workshop. Monitoring runs while this page is open.").foregroundStyle(.secondary)
        }.font(.callout).padding(20).frame(width: 355)
    }
    private static let legend: [WorkshopState] = [.working, .needsInput, .waitingForAgents, .completed, .interrupted, .idle]
}

enum WorkshopDemo {
    static func caption(step: Int) -> String {
        switch step % 5 {
        case 1: return "A subagent needs your input."
        case 2: return "The test run finished. Its session stays open."
        case 3: return "A session closed. Its team heads out."
        case 4: return "A new project opens and moves in."
        default: return "One workshop per project. Its sessions share the room."
        }
    }
    static func agents(step: Int, now: Date) -> [WorkshopAgent] {
        let stage = step % 5
        func agent(_ id: String, project: String, title: String, state: WorkshopState, parent: String? = nil, source: UsageSource = .codex, order: Double = 0, tool: WorkshopToolKind = .edit) -> WorkshopAgent {
            WorkshopAgent(id: WorkshopAgent.key(profile: "demo", source: source, session: id), sessionID: id, profileID: "demo", source: source,
                parentSessionID: parent, projectPath: "/Demo/" + project, title: title,
                model: source == .codex ? "gpt-5.6-terra" : "claude-sonnet-5", state: state, activity: state == .needsInput ? "Choose which design to use" : state == .usingTool ? tool.label : state.label,
                tool: state == .usingTool ? tool : nil, lastActivity: now, openedAt: now.addingTimeInterval(order), events: [WorkshopEvent(id: id, date: now, state: state, label: state.label)])
        }
        var result = [
            agent("studio", project: "TkTracker", title: "Build the pixel workshops", state: .working),
            agent("design", project: "TkTracker", title: "Design the room scene", state: stage == 1 ? .needsInput : .usingTool, parent: "studio", order: 1),
            agent("tests", project: "TkTracker", title: "Verify session lifecycle", state: stage >= 2 ? .completed : .usingTool, parent: "studio", order: 2, tool: .run),
            agent("notes", project: "TkTracker", title: "Draft the release notes", state: stage >= 2 ? .working : .completed, source: .claude, order: 2.5),
            agent("website", project: "Portfolio", title: "Polish the project gallery", state: .idle, source: .claude, order: 3),
        ]
        if stage != 3 {
            result.append(agent("api", project: "TrailForge", title: "Review API changes", state: .waitingForAgents, order: 4))
            result.append(agent("review", project: "TrailForge", title: "Review the implementation", state: .working, parent: "api", order: 5))
            result.append(agent("auth", project: "TrailForge", title: "Audit the auth flow", state: .usingTool, parent: "api", order: 5.1, tool: .search))
            result.append(agent("schema", project: "TrailForge", title: "Check the migrations", state: .usingTool, parent: "api", order: 5.2, tool: .read))
            result.append(agent("docs", project: "TrailForge", title: "Update the API docs", state: .working, parent: "api", order: 5.3))
        }
        if stage == 4 { result.append(agent("new", project: "Notebook", title: "Start a new idea", state: .working, source: .claude, order: 6)) }
        return result
    }
    /// Sample recorded tokens, so demo desks carry paper stacks.
    static func tokens(for agents: [WorkshopAgent]) -> [String: Int] {
        let samples = ["studio": 3_400_000, "design": 420_000, "tests": 96_000, "notes": 150_000, "website": 1_800_000, "api": 12_000_000,
                       "review": 260_000, "auth": 80_000, "schema": 40_000, "docs": 20_000, "new": 4_000]
        var result: [String: Int] = [:]
        for agent in agents { if let value = samples[agent.sessionID] { result[agent.id] = value } }
        return result
    }
}
