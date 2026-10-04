import Foundation

// Minimal assertion harness for the macOS logic-test executables (DESIGN §F.2).
// Every suite's main.swift calls these helpers and ends with `summary()`.
// A failing check prints `FAIL <name>: <detail>`; `summary()` exits 1 if anything failed.

@MainActor private var failureCount = 0
@MainActor private var checkCount = 0
@MainActor private var currentSection = ""

/// Prefixes subsequent check names with `section/` in failure messages.
@MainActor func section(_ name: String) { currentSection = name }

@MainActor private func qualified(_ name: String) -> String { currentSection.isEmpty ? name : "\(currentSection)/\(name)" }

@MainActor @discardableResult
func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) -> Bool {
    checkCount += 1
    if !condition {
        failureCount += 1
        let d = detail()
        print("FAIL \(qualified(name)): \(d.isEmpty ? "condition is false" : d) [\(file):\(line)]")
    }
    return condition
}

@MainActor @discardableResult
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    check(actual == expected, name, "expected \(String(reflecting: expected)), got \(String(reflecting: actual))", file: file, line: line)
}

@MainActor @discardableResult
func expectApprox(_ actual: Double?, _ expected: Double, _ name: String, tolerance: Double = 1e-9, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    guard let actual else { return check(false, name, "expected \(expected), got nil", file: file, line: line) }
    return check(abs(actual - expected) <= tolerance, name, "expected \(expected) ± \(tolerance), got \(actual)", file: file, line: line)
}

@MainActor @discardableResult
func expectNil<T>(_ value: T?, _ name: String, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    check(value == nil, name, "expected nil, got \(String(reflecting: value))", file: file, line: line)
}

/// Runs `body`; records a failure (with the error) if it throws. Returns the value on success.
@MainActor func expectNoThrow<T>(_ name: String, file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> T) -> T? {
    do {
        let v = try body()
        checkCount += 1
        return v
    } catch {
        check(false, name, "threw \(error)", file: file, line: line)
        return nil
    }
}

@MainActor func expectThrows(_ name: String, file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        check(false, name, "expected an error, none thrown", file: file, line: line)
    } catch {
        checkCount += 1
    }
}

/// Decodes a JSON fixture with a plain `JSONDecoder()` (no key strategy, as the app does).
@MainActor func decodeFixture<T: Decodable>(_ type: T.Type, _ json: String, _ name: String, file: StaticString = #fileID, line: UInt = #line) -> T? {
    expectNoThrow(name, file: file, line: line) { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
}

/// Encodes with sorted keys and parses back to a JSON object for key inspection.
@MainActor func encodedObject<T: Encodable>(_ value: T, _ name: String, file: StaticString = #fileID, line: UInt = #line) -> [String: Any]? {
    expectNoThrow(name, file: file, line: line) { () -> [String: Any] in
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return obj
    }
}

/// Prints the result and terminates: exit 0 when every check passed, otherwise exit 1.
@MainActor func summary() -> Never {
    if failureCount > 0 {
        print("logic tests: \(failureCount) of \(checkCount) checks FAILED")
        exit(1)
    }
    print("logic tests: all \(checkCount) checks passed")
    exit(0)
}
