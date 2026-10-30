import XCTest
@testable import TapQVoiceIO

/// The verbatim rule, pinned with fixtures. A consent prompt
/// whose reading fails this check does not open the gate, so a false `true` here is the
/// expensive mistake and a false `false` costs one re-ask.
final class VerbatimCheckTests: XCTestCase {

    func testNormalizationCaseFoldsAndSplitsOnSymbols() {
        XCTAssertEqual(VerbatimCheck.tokens("R-F"), ["r", "f"])
        XCTAssertEqual(VerbatimCheck.tokens("r f"), ["r", "f"])
        XCTAssertEqual(VerbatimCheck.tokens("rf"), ["rf"])
        XCTAssertEqual(VerbatimCheck.tokens("rm -rf ./build && npm run build"),
                       ["rm", "rf", "/", "build", "&", "&", "npm", "run", "build"])
        XCTAssertEqual(VerbatimCheck.tokens("ls ~/a|b>c<d;$e*"),
                       ["ls", "~", "/", "a", "|", "b", ">", "c", "<", "d", ";", "$", "e", "*"])
        XCTAssertEqual(VerbatimCheck.tokens("Start Claude Code in a folder?"),
                       ["start", "claude", "code", "in", "a", "folder"])
        XCTAssertEqual(VerbatimCheck.tokens("  --  "), [])
    }

    func testAFlaggedCommandReadAsLettersIsVerbatim() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: "Claude Code wants to run rm -rf ./build && npm run build. Allow it?",
            heard: "Claude Code wants to run rm r f dot slash build and and npm run build. "
                + "Allow it?"))
    }

    /// Live, `&&` was read as one "and". `>>` still needs both: it is not `>`.
    func testADoubledAmpersandMayBeReadAsOneAnd() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "run git status && ls -la ~/project | head -5",
                                               heard: "run git status and ls -la ~/project | head -5"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "run a && b", heard: "run a ampersand ampersand b"))
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "run a && b", heard: "run a b"))
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "run a >> log", heard: "run a greater than log"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "run a >> log",
                                               heard: "run a greater than greater than log"))
    }

    /// Each input token is one or more consecutive transcript tokens joined: rm = r+m, rf = r+f.
    func testAFlagSpelledOutLetterByLetterIsVerbatim() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: "Claude Code wants to run rm -rf ./build. Allow it?",
            heard: "Claude Code wants to run r m r f dot slash build. Allow it?"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "edit TapQKernel",
                                               heard: "edit tap q kernel"))
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "run rm -rf", heard: "run r m"),
                       "half of a flag is not the flag")
    }

    func testDoubleDashFlagsReadAloudAreVerbatim() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: "Codex wants to run git push --force-with-lease origin main. Allow it?",
            heard: "Codex wants to run git push dash dash force with lease origin main. "
                + "Allow it?"))
    }

    /// Live 2026-10-11, a Codex command was read with "single quote" and "double dash".
    /// The words excuse only what the voice adds: an input word "double" must still be said.
    func testQuotesAndDashesNamedSingleOrDoubleAreVerbatim() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: "Codex wants to run curl --head 'https://example.com'. Allow it?",
            heard: "Codex wants to run curl double dash head single quote https colon slash slash "
                + "example dot com single quote. Allow it?"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "run echo \"hi\"",
                                               heard: "run echo double quote hi double quote"))
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "run the double check", heard: "run the check"))
    }

    func testAURLReadAloudIsVerbatim() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: "Claude Code wants to fetch https://github.com/openai/codex. Allow it?",
            heard: "Claude Code wants to fetch https colon slash slash github dot com slash "
                + "openai slash codex. Allow it?"))
    }

    func testADottedPathReadAloudIsVerbatim() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: "Claude Code wants to edit Sources/TapQKernel/Kernel.swift. Allow it?",
            heard: "Claude Code wants to edit Sources slash TapQKernel slash Kernel dot swift. "
                + "Allow it?"))
    }

    func testAParaphraseIsNotVerbatim() {
        XCTAssertFalse(VerbatimCheck.isVerbatim(
            input: "Claude Code wants to run npm install. Allow it?",
            heard: "Claude Code would like to install npm packages. Should I allow it?"))
    }

    func testAReorderedReadingIsNotVerbatim() {
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "allow it", heard: "it allow"))
    }

    func testAMissingTranscriptIsNotVerbatim() {
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "Allowed.", heard: ""))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "", heard: ""),
                      "nothing to say is said by saying nothing")
    }

    /// "point" is the spoken dot of a version, so "two point one" is "2.1".
    func testVersionNumbersReadWithPointAreVerbatim() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "Update to 2.1?",
                                               heard: "Update to two point one?"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: "TapQ supports 2.1.260 through 2.1.293.",
            heard: "TapQ supports two point one point two sixty through two point one point "
                + "two ninety three."))
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "Update to 2.1?",
                                                heard: "Update to two point two?"))
    }

    // MARK: - Required symbols

    func testADestructiveCommandReadWithoutItsTildeIsNotVerbatim() {
        let input = "Claude Code wants to run rm -rf ~. Allow it?"
        XCTAssertFalse(VerbatimCheck.isVerbatim(
            input: input, heard: "Claude Code wants to run rm r f. Allow it?"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: input, heard: "Claude Code wants to run rm dash r f tilde. Allow it?"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(
            input: input, heard: "Claude Code wants to run rm r f home. Allow it?"))
    }

    func testEveryRequiredSymbolIsSaidByItselfOrByName() {
        let names: [String: [String]] = [
            "~": ["tilde", "home"], "/": ["slash"], "*": ["star", "asterisk"],
            "|": ["pipe"], ">": ["greater than"], "<": ["less than"],
            ";": ["semicolon"], "&": ["and", "ampersand"], "$": ["dollar"],
        ]
        XCTAssertEqual(Set(names.keys), Set(VerbatimCheck.requiredSymbols.keys.map(String.init)))
        for (symbol, spoken) in names {
            let input = "cat a " + symbol + " b"
            XCTAssertFalse(VerbatimCheck.isVerbatim(input: input, heard: "cat a b"), symbol)
            XCTAssertTrue(VerbatimCheck.isVerbatim(input: input, heard: input), symbol)
            for name in spoken {
                XCTAssertTrue(VerbatimCheck.isVerbatim(input: input, heard: "cat a " + name + " b"),
                              name)
            }
        }
    }

    // MARK: - Insertions

    func testAnInsertedClauseIsNotVerbatim() {
        let input = "Claude Code wants to run rm -rf ./build. Allow it?"
        XCTAssertFalse(VerbatimCheck.isVerbatim(
            input: input,
            heard: "Claude Code wants to run rm r f dot slash build. It's safe. Allow it?"))
        XCTAssertFalse(VerbatimCheck.isVerbatim(
            input: input,
            heard: "Claude Code wants to run rm r f dot slash build. Allow it? It's safe."))
    }

    func testOnlyFillersMayBeInserted() {
        for filler in VerbatimCheck.fillers {
            XCTAssertTrue(VerbatimCheck.isVerbatim(input: "allow it",
                                                   heard: filler + " allow " + filler + " it"),
                          filler)
        }
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "allow it", heard: "allow it not"))
    }

    // MARK: - Numbers

    func testNumberWordsMatchDigits() {
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "sleep 40", heard: "sleep forty"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "sleep forty", heard: "sleep 40"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "port 8080", heard: "port eighty eighty"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "in 2026", heard: "in twenty twenty six"))
        XCTAssertTrue(VerbatimCheck.isVerbatim(input: "wait 3000 ms",
                                               heard: "wait three thousand m s"))
        XCTAssertFalse(VerbatimCheck.isVerbatim(input: "sleep 40", heard: "sleep fourteen"))
    }

    func testNumberWordsGroupAsTheyAreSpoken() {
        XCTAssertEqual(VerbatimCheck.digits(["twenty", "twenty", "six"]), ["20", "26"])
        XCTAssertEqual(VerbatimCheck.digits(["eighty", "eighty"]), ["80", "80"])
        XCTAssertEqual(VerbatimCheck.digits(["two", "sixty"]), ["2", "60"])
        XCTAssertEqual(VerbatimCheck.digits(["three", "thousand"]), ["3000"])
        XCTAssertEqual(VerbatimCheck.digits(["two", "thousand", "twenty", "six"]), ["2026"])
        XCTAssertEqual(VerbatimCheck.digits(["one", "hundred", "five", "port"]), ["105", "port"])
        XCTAssertEqual(VerbatimCheck.digits(["nineteen", "hundred", "ninety", "nine"]), ["1999"])
    }
}
