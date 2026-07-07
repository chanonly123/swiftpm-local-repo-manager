import Foundation

// Logs to the console in DEBUG and always to a per-session file (see FileLogger) so users
// can share logs when hitting hard-to-reproduce issues. The message is evaluated in every
// build now — that's the cost of persisting it — so keep logging moderate.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    let message = message()
    #if DEBUG
    print(message)
    #endif
    FileLogger.shared.log(message)
}
