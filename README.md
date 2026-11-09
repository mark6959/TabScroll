# TabScroll

TabScroll is a macOS menu bar app that switches browser tabs when you scroll over the tab strip or vertical tab sidebar. It works with a mouse wheel or trackpad and supports Brave, Chrome, Edge, and Firefox.

## Build and run

1. Open `MacBrowserTabScroll.xcodeproj` in Xcode and select **My Mac**.
2. In the app target’s **Signing & Capabilities** settings, select your own development team if Xcode requests one.
3. Press **⌘R**. Open TabScroll from the menu bar and enable **Tab Switching**.
4. Grant Accessibility access when prompted. If TabScroll asks for Input Monitoring, grant it in System Settings and reopen the app.

The project currently targets macOS 27.2. Older macOS versions and Intel Macs still need runtime testing before they can be listed as supported.

To run the app outside Xcode, build the app and use **Show in Finder** on the app in Xcode’s **Products** group. Copy the app to **Applications** and open it there. You can then enable **Launch at Login** in TabScroll.

## Controls

- **Trackpad sensitivity** sets how much movement triggers a switch. **Cooldown** sets the minimum time between switches.
- **Single Tab per Swipe** limits a trackpad swipe to one switch. Its **Hotkeys** menu lets you assign a shortcut to toggle the mode or activate it only while held.
- **Scroll Anywhere** lets you hold a chosen shortcut and scroll inside the focused browser window. Hold it together with the Single Tab shortcut to switch one tab per swipe from the webpage.
- **Reverse Direction**, browser checkboxes, and **Launch at Login** are available in the menu.

TabScroll uses macOS Accessibility to identify tab areas and Core Graphics to handle input. The Lua prototype in `Reference/` is included for development reference. The app runs without Hammerspoon.
