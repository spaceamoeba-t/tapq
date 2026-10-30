@_exported import Foundation

private let failureLock = NSLock()
nonisolated(unsafe) private var failureList: [String] = []
nonisolated(unsafe) private var teardowns: [() -> Void] = []

public func xctTakeFailures() -> [String] {
    failureLock.lock(); defer { failureLock.unlock() }
    let taken = failureList; failureList = []; return taken
}

public func xctRunTeardowns() {
    let blocks = teardowns; teardowns = []
    blocks.reversed().forEach { $0() }
}

private func record(_ message: String, _ file: StaticString, _ line: UInt) {
    failureLock.lock()
    failureList.append("\(("\(file)" as NSString).lastPathComponent):\(line): \(message)")
    failureLock.unlock()
}

open class XCTestCase: NSObject {
    public override init() { super.init() }
    open func setUp() {}
    open func tearDown() {}
    open func setUp() async throws {}
    open func tearDown() async throws {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
    public func expectation(description: String) -> XCTestExpectation { XCTestExpectation(description: description) }
    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval, enforceOrder: Bool = false) {}
    public func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval = .infinity, enforceOrder: Bool = false) async {}
    public func addTeardownBlock(_ block: @escaping () -> Void) { teardowns.append(block) }
}

public struct XCTSkip: Error { public init(_ message: String? = nil, file: StaticString = #filePath, line: UInt = #line) {} }

private func check(_ body: () throws -> String?, _ message: () -> String, _ file: StaticString, _ line: UInt) {
    do {
        if let failure = try body() { record("\(failure) \(message())", file, line) }
    } catch {
        record("threw \(error) \(message())", file, line)
    }
}

public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ try e() ? nil : "XCTAssertTrue failed" }, m, file, line) }
public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ try e() ? "XCTAssertFalse failed" : nil }, m, file, line) }
public func XCTAssert(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ try e() ? nil : "XCTAssert failed" }, m, file, line) }
public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let x = try a(), y = try b(); return x == y ? nil : "XCTAssertEqual failed: (\(x)) != (\(y))" }, m, file, line) }
public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let x = try a(), y = try b(); return abs(x - y) <= accuracy ? nil : "XCTAssertEqual failed: (\(x)) != (\(y))" }, m, file, line) }
public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let x = try a(), y = try b(); return x != y ? nil : "XCTAssertNotEqual failed: (\(x))" }, m, file, line) }
public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let v = try e(); return v == nil ? nil : "XCTAssertNil failed: \(v!)" }, m, file, line) }
public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ try e() == nil ? "XCTAssertNotNil failed" : nil }, m, file, line) }
public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let x = try a(), y = try b(); return x > y ? nil : "XCTAssertGreaterThan failed: \(x) <= \(y)" }, m, file, line) }
public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let x = try a(), y = try b(); return x >= y ? nil : "XCTAssertGreaterThanOrEqual failed: \(x) < \(y)" }, m, file, line) }
public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let x = try a(), y = try b(); return x < y ? nil : "XCTAssertLessThan failed: \(x) >= \(y)" }, m, file, line) }
public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    check({ let x = try a(), y = try b(); return x <= y ? nil : "XCTAssertLessThanOrEqual failed: \(x) > \(y)" }, m, file, line) }
public func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ handler: (_ error: Error) -> Void = { _ in }) {
    do { _ = try e(); record("XCTAssertThrowsError failed: did not throw \(m())", file, line) } catch { handler(error) } }
public func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try e() } catch { record("XCTAssertNoThrow failed: \(error) \(m())", file, line) } }
public func XCTFail(_ m: String = "", file: StaticString = #filePath, line: UInt = #line) { record("XCTFail \(m)", file, line) }
public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let v = try e() else { record("XCTUnwrap failed \(m())", file, line); throw XCTSkip() }
    return v
}

open class XCTestExpectation: NSObject, @unchecked Sendable {
    public init(description: String) { super.init() }
    open var isInverted = false
    open var expectedFulfillmentCount = 1
    open var assertForOverFulfill = true
    open func fulfill() {}
}
