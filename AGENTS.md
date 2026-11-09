# TabScroll

TabScroll is a lightweight, standalone macOS menu-bar app written in Swift and SwiftUI. It switches browser tabs when the pointer is over the horizontal tab strip or vertical tab sidebar and the user scrolls with a mouse wheel or trackpad.

## Reference and compatibility

- Read `Reference/init.lua` before changing detection or gesture behavior. Treat it as the tested behavior baseline and leave it untouched. The native app must work without Hammerspoon.
- Support Brave, Chrome, Edge, and Firefox, including horizontal strips and expanded, resized, and collapsed vertical sidebars. Verify address bars, webpage content, and unrelated sidebars as negative cases.
- Keep each browser's detector and fallback rules identifiable. Preserve the Lua probe locations, geometry thresholds, and cache behavior until side-by-side verification gives a reason to change them.
- Preserve the prototype defaults: a 40-point continuous-scroll threshold, a threshold of one for discrete wheel events, a 50 ms switch cooldown, a 300 ms idle reset, and reverse direction enabled. Preserve accumulation resets and momentum handling.
- Pass scrolling through when disabled, outside a confirmed tab region, or when the target is uncertain. Recheck browser and focused window before sending a tab shortcut.

## Architecture and workflow

- Use native Core Graphics events and macOS Accessibility. Keep event handling, browser detection, gesture decisions, and SwiftUI controls separate. Minimize work on the scroll path, bound Accessibility lookups, and avoid idle polling.
- Provide enable and disable, trackpad sensitivity, reverse direction, per-browser toggles, and launch at login. Keep settings local and make permission and login-item status clear.
- Work incrementally. Build the macOS scheme in Xcode and explain how to verify each milestone in beginner-friendly language. Verify detection against the prototype before enabling automatic interception. Run one implementation at a time during comparison.
- Test gestures and detector boundaries with focused tests where they catch regressions. Manually verify both input devices, browser layouts, multiple windows, focus changes, permissions, and normal scrolling outside the tab region. Record which checks need a live browser or user-granted permission.
- Keep macOS 27.2 as the initial test target. Choose a public minimum macOS version after compatibility testing. The eventual distribution goal is a free, open-source app on GitHub.
