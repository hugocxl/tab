import CoreFoundation

/// Let AppKit finish the TextView releases queued by synchronous native stress
/// fixtures before the next test starts its asynchronous operation deadline.
@MainActor
func finishAgentNativeFixtureCleanup() async {
    await withCheckedContinuation { continuation in
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            continuation.resume()
        }
        CFRunLoopWakeUp(runLoop)
    }
}
