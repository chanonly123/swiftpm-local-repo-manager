import Foundation

// Lightweight logging that compiles out of release builds. `message` is an @autoclosure,
// so in a release build the string (and any interpolation it performs) is never evaluated.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
