import Foundation

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "report", "usage":
            exit(CLIReport.run(arguments: Array(args.dropFirst())))
        case "--help", "-h", "help":
            print("""
            TkTracker — Claude Code token & cost tracker for macOS

            Run with no arguments to start the menu bar app.

            Commands:
              report [--json|--csv] [--range today|week|month|quarter|all] [--transcripts-only]
                  Print a usage report. --json emits the full dashboard stats;
                  --csv emits per-day, per-model rows. By default the report blends
                  in estimated pre-cleanup history from Claude Code's stats cache;
                  --transcripts-only restricts it to exact transcript data.

            Environment:
              CLAUDE_CONFIG_DIR   Override the Claude data directory
                                  (default ~/.claude; sessions read from <dir>/projects).
            """)
        default:
            TkTrackerApp.main()
        }
    }
}
