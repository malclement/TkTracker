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
              report [--json] [--range today|week|month|quarter|all] [--transcripts-only]
                  Print a usage report to the terminal. By default the report blends
                  in estimated pre-cleanup history from Claude Code's stats cache;
                  --transcripts-only restricts it to exact transcript data.
            """)
        default:
            TkTrackerApp.main()
        }
    }
}
