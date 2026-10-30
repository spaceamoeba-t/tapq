import re
import sys

# usage: gen.py out_main.swift module... -- test_files...
args = sys.argv[2:]
split = args.index("--")
modules, files = args[:split], args[split + 1:]
entries = []
known = set()
for path in files:
    cls = None
    for line in open(path):
        match = re.match(r'(?:@MainActor )?(?:final )?class (\w+): XCTestCase', line)
        if match:
            cls = match.group(1)
            known.add(cls)
            continue
        # An extension of a test class seen above holds tests of that class too.
        extension = re.match(r'extension (\w+)', line)
        if extension:
            cls = extension.group(1) if extension.group(1) in known else None
            continue
        if re.match(r'(final class|class|struct|enum|private|extension) ', line):
            cls = None
        match = re.match(r'    func (test\w+)\(\)( async)?( throws)?', line)
        if match and cls:
            call = ('try ' if match.group(3) else '') + ('await ' if match.group(2) else '') + f't.{match.group(1)}()'
            entries.append((f'{cls}.{match.group(1)}',
                            f'let t = {cls}(); try t.setUpWithError(); try await t.setUp(); '
                            f'{call}; try await t.tearDown()'))

lines = ['import Foundation', 'import XCTest'] + [f'@testable import {m}' for m in modules] + [
    '',
    'nonisolated(unsafe) var current = -1',
    '',
    '@MainActor func runAll() async {',
    '    var failed = 0',
    '    for (index, (name, body)) in tests.enumerated() {',
    '        current = index',
    '        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {',
    '            if current == index { print("TIMEOUT \\(name)"); exit(2) }',
    '        }',
    '        do { try await body() } catch { print("     threw \\(error)") }',
    '        xctRunTeardowns()',
    '        let failures = xctTakeFailures()',
    '        if failures.isEmpty { print("ok   \\(name)") } else {',
    '            failed += 1',
    '            print("FAIL \\(name)")',
    '            failures.forEach { print("     \\($0)") }',
    '        }',
    '    }',
    '    current = -1',
    '    print("\\(tests.count - failed)/\\(tests.count) passed")',
    '    exit(failed == 0 ? 0 : 1)',
    '}',
    '',
    'let tests: [(String, @MainActor () async throws -> Void)] = [',
]
lines += [f'    ("{name}", {{ {body} }}),' for name, body in entries]
lines += [']', '', 'setvbuf(stdout, nil, _IONBF, 0)', 'Task { @MainActor in await runAll() }', 'dispatchMain()']
open(sys.argv[1], 'w').write('\n'.join(lines) + '\n')
print(f'{len(entries)} tests')
