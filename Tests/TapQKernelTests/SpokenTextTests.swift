import XCTest
@testable import TapQKernel

/// Replies spoken without their markdown (decided 2026-10-11).
final class SpokenTextTests: XCTestCase {
    static let examples: [(markdown: String, spoken: String)] = [
        ("Created `hello` containing `hi`.\n\nThe check script completed with argument `60` and output:\n```text\ndone\n```",
         "Created hello containing hi.\n\nThe check script completed with argument 60 and output:\ndone"),
        ("The [README.md](/var/folders/x/README.md) contains only one heading:\n\n> e2e workspace\n\nThere are no other details.",
         "The README.md contains only one heading:\n\ne2e workspace\n\nThere are no other details."),
        ("See ![diagram](img/a.png) and [the docs](https://x.y/z).", "See diagram and the docs."),
        ("  >> nested quote\nx > y stays", "nested quote\nx > y stays"),
        ("Status line: `HTTP/2 200`", "Status line: HTTP/2 200"),
        ("   ```bash\nnpm test\n   ```", "npm test"),
        ("```\n```", ""),
        ("Plain words, [not a link] (here).", "Plain words, [not a link] (here)."),
        // 2026-10-12: emphasis, headings, bullets and rules (live: "**Tests:**" was read out).
        ("**Bold** and __also bold__, *italic* and _also italic_, ~~gone~~.",
         "Bold and also bold, italic and also italic, gone."),
        ("## Summary ##\n- **Tests:** 50 pass\n* `__init__.py` stays, so does snake_case_name\n---\n1. Done",
         "Summary\nTests: 50 pass\n__init__.py stays, so does snake_case_name\n\n1. Done"),
        ("Globs like *.py and a*b*c, 2 * 3 * 4, and **`tally/cli.py`** read as written.",
         "Globs like *.py and a*b*c, 2 * 3 * 4, and tally/cli.py read as written."),
        ("```python\nprint(f(**a, **b))\n# not a heading\n- not a bullet\n```\n(*Done*) `*`",
         "print(f(**a, **b))\n# not a heading\n- not a bullet\n(Done) *"),
        ("An __init__.py and a `__main__` *without* backquotes", "An __init__.py and a __main__ without backquotes"),
    ]

    /// Whether a reply marks a name the agents' way (maintainer, 2026-10-16). kernel.py's
    /// `marks_names` mirrors it, and its selftest runs this same table.
    static let nameExamples: [(markdown: String, marks: Bool)] = [
        ("Created `two` containing `two`.", true),
        ("Done.", false),
        ("Paris.", false),
        ("See [the docs](https://x.y/z).", true),
        ("![diagram](img/a.png)", true),
        ("```\nnpm test\n```", true),
        ("   ```bash\nls\n   ```", true),
        ("A ` lone backquote", false),
        ("An empty `` pair", false),
        ("Prices: 2 * 3 = 6, and/or more.", false),
        ("I edited /Users/me/app/main.swift.", false),
        ("Plain words, [not a link] (here).", false),
    ]

    func testANameIsMarkedByTheAgentsOwnMarkup() {
        for (markdown, marks) in Self.nameExamples {
            XCTAssertEqual(SpokenText.marksNames(markdown), marks, markdown)
        }
    }

    func testTheExamples() {
        for (markdown, spoken) in Self.examples {
            XCTAssertEqual(SpokenText.plain(markdown), spoken, markdown)
        }
    }

    func testRepliesAreSpokenWithoutMarkdownAndRequestsAreNot() {
        XCTAssertEqual(Sentences.finished(.codex, "Status line: `HTTP/2 200`"), "Codex says: Status line: HTTP/2 200")
        XCTAssertEqual(Sentences.finished(.codex, "```\n```"), "Codex is done.")
        XCTAssertEqual(Sentences.summary(.claude, "A minimal `sh` script."),
                       "Claude Code says, in short: A minimal sh script.")
        XCTAssertEqual(Sentences.readAll(.claude, held: "> quoted `x`"), "Claude Code said: quoted x")
        let request = PermissionRequest(id: "p", tool: "Bash", inputJSON: "{}",
                                        command: "echo `date` > out.txt")
        XCTAssertEqual(Sentences.permission(.claude, request),
                       "Claude Code wants to run echo `date` > out.txt. Allow it?")
    }
}
