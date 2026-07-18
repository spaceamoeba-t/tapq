## Summary

Describe the problem and the outcome of this change.

## Verification

- [ ] `swift build`
- [ ] `swift test`
- [ ] `scripts/check-public-boundary.sh`
- [ ] Relevant macOS runtime or packaging checks, if applicable

## Checklist

- [ ] The change is scoped to the smallest owning target.
- [ ] Behavior changes include tests.
- [ ] Portable-logic targets do not import Apple-only or direct POSIX APIs.
- [ ] Documentation reflects user-visible changes.
- [ ] No secrets, private fixtures, raw captures, or proprietary assets are included.
