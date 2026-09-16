import SwiftUI

struct WorkshopView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: String?
    @State private var project = ""
    @State private var page = 0
    @State private var zoom = 1.0
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
    private var pages: Int { max(1, (islands.count + 3) / 4) }
    private var selected: WorkshopAgent? {
        islands.flatMap(\.agents).first { $0.id == selectedID } ?? islands.first?.lead
    }
    private var selectedIsland: WorkshopIsland? { islands.first { $0.agents.contains { $0.id == selected?.id } } }
    private var visibleIslands: [WorkshopIsland] {
        if following, let selectedIsland { return [selectedIsland] }
        return Array(islands.dropFirst(min(page, pages - 1) * 4).prefix(4))
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
                        .help("Explore sample islands and session lifecycle events")
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
            selectedID = nil; project = ""; page = 0; zoom = 1; following = true; demoStep = 0; demoDate = Date()
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
                Text("Floating Workshops").font(.system(size: 23, weight: .semibold, design: .rounded))
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
            WorkshopScene(islands: visibleIslands, selectedID: selected?.id, zoom: zoom, cameraReset: cameraReset,
                presentationID: following ? "follow/" + (selectedIsland?.id ?? "empty") : "overview/\(page)",
                reducedMotion: reducedMotion, dark: colorScheme == .dark, onSelect: select)
            if islands.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "cloud").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(store.workshops.hasLoaded || demo ? "Clear skies for now" : "Looking for your agents…")
                        .font(.title3.weight(.medium))
                    Text("Open a Claude Code or Codex session\nand its workshop will appear here.")
                        .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                    if !demo { Button("Explore a demo") { demo = true }.padding(.top, 5) }
                }.padding(24)
            }
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(following ? (selectedIsland?.lead.projectName ?? "Your sky") : "All islands")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                        if following, let agent = selected {
                            Label(agent.state.label, systemImage: agent.state.symbol)
                                .font(.caption.weight(.medium)).foregroundStyle(agent.state.tint)
                        } else {
                            Text("\(islands.count) sessions · \(islands.flatMap(\.subagents).count) subagents")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if demo { Text(WorkshopDemo.caption(step: demoStep)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button {
                        following.toggle(); zoom = 1; cameraReset += 1
                    } label: {
                        Label(following ? "All islands" : "Follow session", systemImage: following ? "square.grid.2x2" : "scope")
                    }.controlSize(.small).disabled(islands.isEmpty)
                    if demo {
                        Button { demoStep += 1 } label: { Label("Next event", systemImage: "forward.end") }
                            .controlSize(.small)
                    }
                }
                Spacer()
                HStack {
                    if !islands.isEmpty {
                        Text("Drag to look around").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        Button { zoom = max(0.7, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                            .accessibilityLabel("Zoom out").disabled(zoom <= 0.7)
                        Button("Fit") { zoom = 1; cameraReset += 1 }.font(.caption)
                        Button { zoom = min(1.65, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                            .accessibilityLabel("Zoom in").disabled(zoom >= 1.65)
                    }.buttonStyle(.borderless).padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(16)
        }.clipped().frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Label("\(islands.flatMap(\.agents).filter { $0.state == .idle || $0.state == .completed }.count) resting", systemImage: "moon")
            if !demo && store.workshops.hasUncertainty {
                Button { showingInfo = true } label: { Label("Some status unavailable", systemImage: "questionmark.circle") }.buttonStyle(.plain)
            }
            Spacer()
            if pages > 1 && !following {
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).accessibilityLabel("Previous islands")
                Text("\(page + 1) / \(pages)").monospacedDigit()
                Button { page = min(pages - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= pages - 1).accessibilityLabel("Next islands")
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
                    ForEach(islands) { island in
                        VStack(alignment: .leading, spacing: 2) {
                            rosterButton(island.lead, isLead: true)
                            if island.id == selectedIsland?.id {
                                ForEach(island.subagents) { agent in
                                    rosterButton(agent, isLead: false)
                                }
                            }
                        }
                        .padding(5)
                        .background(island.id == selectedIsland?.id ? Color.accentColor.opacity(0.08) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }.frame(maxHeight: 260)
        }
    }

    private func rosterButton(_ agent: WorkshopAgent, isLead: Bool) -> some View {
        Button { select(agent.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isLead ? "cube.fill" : "arrow.turn.down.right")
                    .font(.system(size: isLead ? 17 : 12))
                    .foregroundStyle(agent.state.tint)
                    .frame(width: 22, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isLead ? agent.projectName : agent.title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if isLead { Text(agent.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Label(agent.state.label, systemImage: agent.state.symbol)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(agent.state.tint)
                }
                Spacer(minLength: 0)
                if selected?.id == agent.id {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
            }.padding(7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(isLead ? agent.projectName : agent.title), \(agent.state.label)")
    }

    private func inspector(_ agent: WorkshopAgent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(agent.parentSessionID == nil ? "SESSION" : "SUBAGENT").font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: agent.source == .codex ? "terminal" : "sparkle").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(agent.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(agent.projectName + " · " + agent.source.displayName).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(agent.state.label, systemImage: agent.state.symbol).font(.callout.weight(.medium)).foregroundStyle(agent.state.tint)
                    Text(agent.activity).font(.callout).foregroundStyle(.secondary)
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
        if let index = islands.firstIndex(where: { $0.agents.contains(where: { $0.id == id }) }) { page = index / 4 }
        selectedID = id
        following = true; zoom = 1
    }
    private var observationInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A workshop for each open session").font(.headline)
            Text("Islands stay while sessions are loaded, even when agents are idle or a turn is complete. Closing a session removes its island after the next successful checks.")
            Text("Codex may keep a session loaded after its tab closes. Its island leaves when Codex releases the session. Claude Code sessions are matched to their running process.")
            Text("Activity comes from local session events. Missing or unreadable signals show an unavailable status. Waiting for you is shown only when an explicit input or approval request is observed.")
            Text("No prompts or tool output are copied into the workshop. Monitoring runs while this page is open.").foregroundStyle(.secondary)
        }.font(.callout).padding(20).frame(width: 355)
    }
}

enum WorkshopDemo {
    static func caption(step: Int) -> String {
        switch step % 5 {
        case 1: return "A subagent needs your input."
        case 2: return "The test run finished. Its session stays open."
        case 3: return "A session closed. Its island departs."
        case 4: return "A new session opens and joins the sky."
        default: return "Three sessions, each with a place of its own."
        }
    }
    static func agents(step: Int, now: Date) -> [WorkshopAgent] {
        let stage = step % 5
        func agent(_ id: String, project: String, title: String, state: WorkshopState, parent: String? = nil, source: UsageSource = .codex, order: Double = 0) -> WorkshopAgent {
            WorkshopAgent(id: WorkshopAgent.key(profile: "demo", source: source, session: id), sessionID: id, profileID: "demo", source: source,
                parentSessionID: parent, projectPath: "/Demo/" + project, title: title,
                model: source == .codex ? "gpt-5.6-terra" : "claude-sonnet-5", state: state, activity: state == .needsInput ? "Choose which design to use" : state.label,
                lastActivity: now, openedAt: now.addingTimeInterval(order), events: [WorkshopEvent(id: id, date: now, state: state, label: state.label)])
        }
        var result = [
            agent("studio", project: "TkTracker", title: "Build the floating workshops", state: .working),
            agent("design", project: "TkTracker", title: "Design the island scene", state: stage == 1 ? .needsInput : .usingTool, parent: "studio", order: 1),
            agent("tests", project: "TkTracker", title: "Verify session lifecycle", state: stage >= 2 ? .completed : .usingTool, parent: "studio", order: 2),
            agent("website", project: "Portfolio", title: "Polish the project gallery", state: .idle, source: .claude, order: 3),
        ]
        if stage != 3 {
            result.append(agent("api", project: "TrailForge", title: "Review API changes", state: .waitingForAgents, order: 4))
            result.append(agent("review", project: "TrailForge", title: "Review the implementation", state: .working, parent: "api", order: 5))
        }
        if stage == 4 { result.append(agent("new", project: "Notebook", title: "Start a new idea", state: .working, source: .claude, order: 6)) }
        return result
    }
}
