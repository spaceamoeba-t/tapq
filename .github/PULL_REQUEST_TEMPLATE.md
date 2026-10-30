## Summary

Describe the problem and the outcome of this change.

## Verification

- [ ] `swift build`
- [ ] `swift test` (or `scripts/typecheck-tests.sh` and `scripts/host-test.sh` on a Mac without XCTest)
- [ ] `scripts/check-release-version.sh`
- [ ] `scripts/check-public-boundary.sh`
- [ ] A live `tapq-kernel run`, if the change is something the user hears or says

## Checklist

- [ ] The change is scoped to the smallest owning target.
- [ ] Behavior changes include tests.
- [ ] `TapQKernel` and the other portable targets import no Apple-only or direct POSIX API.
- [ ] Documentation reflects user-visible changes.
- [ ] No secrets, private fixtures, raw captures, or unauthorized proprietary assets are included.
- [ ] Any brand asset change has prior written approval and separate contribution terms.
