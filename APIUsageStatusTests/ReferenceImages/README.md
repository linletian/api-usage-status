# Golden Master Reference Images

This directory stores the baseline PNG snapshots used by `MenuBarIconRendererTests`.

## Workflow

1. **First run** (`Cmd+U` or `xcodebuild test`):
   - Tests generate reference PNGs here.
   - Tests **intentionally fail** with the message:
     > "Reference image created at … Re-run test to verify."
   - This is expected — the baseline is being established.

2. **Second run**:
   - Rendered images are compared byte-for-byte against the reference.
   - If the rendering logic has not changed, tests pass.
   - If pixels differ (e.g. after a deliberate change), delete the relevant
     `.png` file(s) and re-run to regenerate.

## Committing

Reference images should be committed to Git so that CI and other developers
share the same baseline.
