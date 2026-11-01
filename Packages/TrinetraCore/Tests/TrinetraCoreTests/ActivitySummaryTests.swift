import XCTest
@testable import TrinetraCore

final class ActivitySummaryTests: XCTestCase {
    func tool(_ name: String, _ input: [String: Any]) -> String {
        ActivitySummary.describe(state: .working, payload: ["tool_name": name, "tool_input": input])
    }

    func testEditShowsFileNameOnly() {
        XCTAssertEqual(tool("Edit", ["file_path": "/Users/x/proj/App/AppModel.swift"]), "Editing AppModel.swift")
    }

    func testBashShowsFirstWordOnly() {
        XCTAssertEqual(tool("Bash", ["command": "API_KEY=secret curl https://x"]), "Running API_KEY=secret")
        XCTAssertEqual(tool("Bash", ["command": "/usr/bin/swift test --parallel"]), "Running swift")
    }

    func testMcpTool() {
        XCTAssertEqual(tool("mcp__github__create_issue", [:]), "Using github")
    }

    func testStatesWithoutTool() {
        XCTAssertEqual(ActivitySummary.describe(state: .working, payload: [:]), "Thinking")
        XCTAssertEqual(ActivitySummary.describe(state: .idle, payload: [:]), "Waiting for your next prompt")
        XCTAssertEqual(ActivitySummary.describe(state: .waiting, payload: ["message": "Claude needs your permission to use Bash"]),
                       "Claude needs your permission to use Bash")
    }

    func testTruncates() {
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(ActivitySummary.describe(state: .waiting, payload: ["message": long]).count, 70)
    }
}
