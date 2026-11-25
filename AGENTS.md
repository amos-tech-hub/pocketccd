# PocketCCD Workspace Rules

## Testing & Verification Workflow
- After routine code edits, run **only** a fast build check (`xcodebuild build`) or the minimal targeted test suite directly related to the change (using `-only-testing:PocketCCDTests/<SuiteName>`).
- **Do NOT** automatically run the full regression test suite (all 149+ tests / full staged sample render matrix) after every edit.
- Run the full test suite **only** when the user explicitly asks to run tests (e.g., "测试", "跑全量测试") or explicitly prepares for a release/archive.
