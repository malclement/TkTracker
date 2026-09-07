import Foundation

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "report", "usage":
            exit(CLIReport.run(arguments: Array(args.dropFirst())))
        case "--version", "-v", "version":
            print("TkTracker \(AppVersion.current)")
        case "--smoke":
            exit(SmokeCheck.run())
        case "--selfcheck":
            exit(SelfCheck.run())
        case "--help", "-h", "help":
            print("""
            TkTracker — Claude Code & Codex token & cost tracker for macOS

            Run with no arguments to start the menu bar app.

            Commands:
              report [--json|--csv] [--range today|week|month|quarter|all]
                     [--source claude|codex|all] [--transcripts-only] [--watch]
                     [--from YYYY-MM-DD --to YYYY-MM-DD | --calendar-month]
                     [--project /absolute/path] [--model canonical-id] [--view name]
                  Print a usage report. --json emits the full dashboard stats;
                  --csv emits per-day, per-source, per-model rows. --source
                  restricts it to one tool (default: all). By default the report
                  blends in estimated pre-cleanup history from Claude Code's
                  stats cache; --transcripts-only restricts it to exact
                  transcript data. --watch redraws every 3s until interrupted.
              --dashboard
                  Open the dashboard on launch.
              --version
                  Print the version and exit.

            Environment:
              CLAUDE_CONFIG_DIR   Override the Claude data directory
                                  (default ~/.claude; sessions read from <dir>/projects).
              CODEX_HOME          Override the Codex data directory
                                  (default ~/.codex; sessions read from <dir>/sessions).
            """)
        default:
            TkTrackerApp.main()
        }
    }
}
