import Foundation
import HelperCore

@main
struct EntryPoint {
    static func main() async {
        // Writes to a closed socket must not kill the daemon.
        signal(SIGPIPE, SIG_IGN)
        let code = await CLI.main(Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}
