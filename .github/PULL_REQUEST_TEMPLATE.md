<!-- One change per pull request. The title says what it does: "Blank secrets in file names" -->

## What changes

<!-- What someone using Rhino or writing a script will see differently, and why. Link the issue: Closes #123. -->

## How it was checked

<!-- What you ran, and against what. The tests passing is the least. Say too what you did not run. -->

- [ ] `cd RhinoCore && swift test` passes
- [ ] The app builds (`xcodegen generate`, then build in Xcode or `Tools/install.sh`)
- [ ] A change to the core comes with a test; a bug fix with a test that fails without it
- [ ] If it changes the script API: `globals.d.ts` says so, and `docs/WRITING-SCRIPTS.md` where it matters
- [ ] If it changes the window: a screenshot is attached

## Anything a reviewer should look at first
