import XCTest
@testable import CCMeterCore

/// The notifier builds an AppleScript program by interpolating a title and body that come from
/// fetched data (limit labels, model names, update-failure text). Before this it lived in the
/// app target with no seam, so none of that escaping was reachable from a test.
final class OsascriptNotifierTests: XCTestCase {
    private func script(title: String, body: String) throws -> String {
        let spy = SpyCommandRunner()
        OsascriptNotifier(runner: spy).post(
            NotificationEvent(id: "id", title: title, body: body)
        )

        let command = try XCTUnwrap(spy.commands.first)
        XCTAssertEqual(command.executable, "/usr/bin/osascript")
        XCTAssertEqual(command.arguments.first, "-e")
        return try XCTUnwrap(command.arguments.last)
    }

    func testBuildsADisplayNotificationScript() throws {
        let script = try script(title: "cc-meter", body: "5h window at 90%")

        XCTAssertEqual(script,
                       #"display notification "5h window at 90%" with title "cc-meter""#)
    }

    /// A quote in the body would otherwise close the string literal early and let the rest of the
    /// text be parsed as AppleScript.
    func testEscapesQuotesSoTextCannotBreakOutOfTheStringLiteral() throws {
        let script = try script(title: "t", body: #"quota" & say "pwned"#)

        XCTAssertFalse(script.contains(#"" & say ""#),
                       "the quote closed the literal: \(script)")
        XCTAssertTrue(script.contains(#"\"quota\\\" & say \\\"pwned\""#) ||
                      script.contains(#"quota\" & say \"pwned"#),
                      "quotes must survive as escaped quotes: \(script)")
    }

    /// Order matters: escaping quotes *before* backslashes turns `\"` into `\\"` — the backslash
    /// gets doubled into a literal backslash and the quote is exposed again.
    func testEscapesBackslashesBeforeQuotes() throws {
        let script = try script(title: "t", body: #"C:\path" & beep"#)

        // The trailing quote must still be escaped after the backslash was doubled.
        XCTAssertTrue(script.hasSuffix(#"with title "t""#))
        XCTAssertTrue(script.contains(#"C:\\path\""#),
                      "backslash must be doubled and the quote still escaped: \(script)")
    }

    func testTitleIsEscapedToo() throws {
        let script = try script(title: #"a "quoted" title"#, body: "b")

        XCTAssertTrue(script.hasSuffix(#"with title "a \"quoted\" title""#), script)
    }

    /// post() runs on the main actor on the refresh path, so it must not wait on a child process.
    func testPostFiresAndForgetsRatherThanWaitingForTheCommand() throws {
        let spy = SpyCommandRunner()

        OsascriptNotifier(runner: spy).post(NotificationEvent(id: "i", title: "t", body: "b"))

        XCTAssertEqual(spy.commands.count, 1)
        XCTAssertNil(spy.commands[0].input)
    }

    /// osascript failing must never take the app down: notifications are a nicety.
    func testALaunchFailureIsSwallowed() {
        let spy = SpyCommandRunner()
        spy.launchError = CommandError.launchFailed("no such file")

        OsascriptNotifier(runner: spy).post(NotificationEvent(id: "i", title: "t", body: "b"))
    }
}
