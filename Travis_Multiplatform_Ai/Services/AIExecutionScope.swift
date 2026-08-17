import Foundation

enum AIExecutionScope {
    @TaskLocal static var context: AIInvocationContext = .general
}
