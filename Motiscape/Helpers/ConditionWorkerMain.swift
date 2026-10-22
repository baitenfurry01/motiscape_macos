
import Darwin

/// Standalone entry point for the condition evaluator's inherited sandbox.
/// The request protocol and JavaScript evaluation remain in the shared source.
@main
enum ConditionWorkerMain {
    static func main() {
        guard WEConditionEvaluator.runWorkerIfRequested() else { exit(64) }
    }
}
