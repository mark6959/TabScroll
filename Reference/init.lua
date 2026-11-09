
-- Browser tab switching by scrolling
-- Hammerspoon configuration

local config = {
    sensitivity = 40,        -- Scroll sensitivity
    cooldown = 0.05,         -- Delay between switches
    reverseDirection = true  -- Invert scroll direction
}

local props = hs.eventtap.event.properties
local accumulated = 0
local lastEventTime = 0
local lastSwitchTime = 0
local lastDirection = 0
local lastWindowKey


local browsers = {
    ["com.brave.Browser"] = true,      -- Brave
    ["com.google.Chrome"] = true,     -- Chrome
    ["com.microsoft.edgemac"] = true, -- Microsoft Edge
    ["org.mozilla.firefox"] = true    -- Firefox
}


local function switchTab(direction, appPID, windowID)
    local key = direction < 0 and "right" or "left"

    if config.reverseDirection then
        key = direction < 0 and "left" or "right"
    end

    -- Defer the shortcut and verify that its target still has focus.
    hs.timer.doAfter(0, function()
        local app = hs.application.frontmostApplication()
        local win = hs.window.focusedWindow()
        if not app or app:pid() ~= appPID or not win or win:id() ~= windowID then
            return
        end
        hs.eventtap.keyStroke({"cmd", "alt"}, key, 0)
    end)
end


-- Dynamic Brave sidebar detection using Accessibility

local axCache = {
    time = 0,
    x = -1,
    y = -1,
    result = false,
    windowKey = ""
}

local function isInBraveSidebar(mouse, frame, targetKey)
    local now = hs.timer.secondsSinceEpoch()

    local windowKey = string.format(
        "%s:%s:%s:%s:%s",
        targetKey, frame.x, frame.y, frame.w, frame.h
    )

    -- Cache briefly to avoid expensive AX queries
    -- on every tiny trackpad movement.
    if now - axCache.time < 0.15
        and math.abs(mouse.x - axCache.x) < 2
        and math.abs(mouse.y - axCache.y) < 2
        and windowKey == axCache.windowKey then
        return axCache.result
    end

    local result = false

    local ok, element = pcall(
        hs.axuielement.systemElementAtPosition,
        mouse
    )

    if ok and element then
        local pathOK, path = pcall(function()
            return element:path()
        end)

        if pathOK and type(path) == "table" then
            for _, node in ipairs(path) do
                local roleOK, role = pcall(function()
                    return node:attributeValue("AXRole")
                end)

                local frameOK, rect = pcall(function()
                    return node:attributeValue("AXFrame")
                end)

                if roleOK and frameOK
                    and role == "AXGroup"
                    and type(rect) == "table"
                    and rect.x and rect.y
                    and rect.w and rect.h then

                    -- Find a tall, narrow group along
                    -- the left edge of the browser.
                    local matches =
                        math.abs(rect.x - frame.x) < 8
                        and rect.w >= 30
                        and rect.w <= 450
                        and rect.w < frame.w * 0.7
                        and rect.h >= frame.h * 0.5
                        and rect.y >= frame.y + 20
                        and rect.y <= frame.y + 260
                        and mouse.x >= rect.x
                        and mouse.x < rect.x + rect.w
                        and mouse.y >= rect.y
                        and mouse.y < rect.y + rect.h

                    
-- Horizontal tab strip detection
-- Uses the actual Accessibility group boundaries.

local horizontalMatches =
    rect.h >= 28
    and rect.h <= 55
    and rect.w >= frame.w * 0.35

    -- Near the top of the browser window
    and rect.y >= frame.y - 3
    and rect.y <= frame.y + 30

    -- Stay inside the browser window
    and rect.x >= frame.x + 20
    and rect.x + rect.w <= frame.x + frame.w + 3

    -- Cursor must be inside this AXGroup
    and mouse.x >= rect.x
    and mouse.x < rect.x + rect.w
    and mouse.y >= rect.y
    and mouse.y < rect.y + rect.h

-- Either vertical or horizontal tabs
if matches or horizontalMatches then
    result = true
    break
end

                end
            end
        end
    end

    axCache = {
        time = now,
        x = mouse.x,
        y = mouse.y,
        result = result,
        windowKey = windowKey
    }

    return result
end


-- Chrome-specific dynamic tab detection
-- Uses the actual AXTabGroup accessibility element

local function isInChromeTabs(mouse)
    local ok, element = pcall(function()
        return hs.axuielement.systemElementAtPosition(mouse)
    end)

    if not ok or not element then
        return false
    end

    local pathOK, path = pcall(function()
        return element:path()
    end)

    if not pathOK or type(path) ~= "table" then
        return false
    end

    for _, node in ipairs(path) do
        local roleOK, role = pcall(function()
            return node:attributeValue("AXRole")
        end)

        if roleOK and role == "AXTabGroup" then
            local frameOK, rect = pcall(function()
                return node:attributeValue("AXFrame")
            end)

            if frameOK
                and type(rect) == "table"
                and rect.x and rect.y
                and rect.w and rect.h then

                return mouse.x >= rect.x
                    and mouse.x < rect.x + rect.w
                    and mouse.y >= rect.y
                    and mouse.y < rect.y + rect.h
            end
        end
    end

    return false
end

-- Microsoft Edge tab detection
-- Uses the webpage boundary to infer the sidebar width.

local edgeCache = {
    time = 0,
    key = "",
    rect = nil
}

local function edgeWebpageFrame(frame, targetKey)
    local now = hs.timer.secondsSinceEpoch()
    local key = string.format("%s:%s:%s:%s:%s",
        targetKey, frame.x, frame.y, frame.w, frame.h)

    if edgeCache.key == key
        and now - edgeCache.time < 0.15 then
        return edgeCache.rect
    end

    -- Inspect a point well inside the webpage.
    local probe = {
        x = frame.x + frame.w - math.min(30, frame.w * 0.1),
        y = frame.y + math.min(250, frame.h * 0.5)
    }

    local rect = nil

    local ok, element = pcall(
        hs.axuielement.systemElementAtPosition,
        probe
    )

    if ok and element then
        local pathOK, path = pcall(function()
            return element:path()
        end)

        if pathOK and type(path) == "table" then
            for _, node in ipairs(path) do
                local roleOK, role = pcall(function()
                    return node:attributeValue("AXRole")
                end)

                if roleOK and role == "AXWebArea" then
                    local frameOK, candidate = pcall(function()
                        return node:attributeValue("AXFrame")
                    end)

                    if frameOK
                        and type(candidate) == "table"
                        and candidate.x and candidate.y
                        and candidate.w and candidate.h
                        and candidate.w > math.max(150, frame.w * 0.12)
                        and candidate.h > frame.h * 0.35 then

                        rect = candidate
                        break
                    end
                end
            end
        end
    end

    edgeCache = {
        time = now,
        key = key,
        rect = rect
    }

    return rect
end

local function isInEdgeTabs(mouse, frame, targetKey)
    local page = edgeWebpageFrame(frame, targetKey)

    if not page then
        return false
    end

    local leftGap = page.x - frame.x

    -- Detect whether a vertical sidebar exists.
    local vertical =
    leftGap >= 32
    and leftGap < frame.w - 160

    if vertical then
        -- Dynamic vertical sidebar boundary
        local sidebarTop = math.max(
            frame.y + 60,
            page.y - 12
        )

        return mouse.x >= frame.x
            and mouse.x < page.x
            and mouse.y >= sidebarTop
            and mouse.y < frame.y + frame.h
    end

    -- Horizontal tab strip fallback
    -- Exclude the address bar below the tabs.
    local tabBottom = math.min(
        frame.y + 45,
        page.y - 20
    )

    return mouse.x >= frame.x + 75
        and mouse.x < frame.x + frame.w - 20
        and mouse.y >= frame.y
        and mouse.y < tabBottom
end

-- Firefox: dynamic horizontal and vertical tab detection

local function isInFirefoxTabs(mouse, frame)
    local ok, element = pcall(
        hs.axuielement.systemElementAtPosition, mouse
    )

    if not ok or not element then return false end

    local pathOK, path = pcall(function()
        return element:path()
    end)

    if not pathOK or type(path) ~= "table" then
        return false
    end

    -- Never treat tab-like elements inside a webpage
    -- as part of Firefox's browser interface.
    for _, node in ipairs(path) do
        local roleOK, role = pcall(function()
            return node:attributeValue("AXRole")
        end)

        if roleOK and role == "AXWebArea" then
            return false
        end
    end

    for _, node in ipairs(path) do
        local roleOK, role = pcall(function()
            return node:attributeValue("AXRole")
        end)

        if roleOK and role == "AXTabGroup" then
            local frameOK, rect = pcall(function()
                return node:attributeValue("AXFrame")
            end)

            if frameOK
                and type(rect) == "table"
                and rect.x and rect.y
                and rect.w and rect.h then

                local inside =
                    mouse.x >= rect.x
                    and mouse.x < rect.x + rect.w
                    and mouse.y >= rect.y
                    and mouse.y < rect.y + rect.h

                local vertical =
                    math.abs(rect.x - frame.x) < 12
                    and rect.h >= frame.h * 0.45
                    and rect.w >= 30
                    and rect.w < frame.w - 100

                local horizontal =
                    rect.h >= 28
                    and rect.h <= 70
                    and rect.y >= frame.y - 5
                    and rect.y <= frame.y + 25
                    and rect.w >= 100

                if inside and (vertical or horizontal) then
                    return true
                end
            end
        end
    end

    return false
end

verticalTabScroll = hs.eventtap.new(
    {hs.eventtap.event.types.scrollWheel},
    function(event)

        local app = hs.application.frontmostApplication()
        local bundleID = app and app:bundleID()
        local win = browsers[bundleID] and hs.window.focusedWindow()
        local windowID = win and win:id()
        if not windowID then
            accumulated = 0
            lastWindowKey = nil
            return false
        end

        local appPID = app:pid()
        local targetKey = string.format("%s:%s", appPID, windowID)
        if targetKey ~= lastWindowKey then
            accumulated = 0
            lastWindowKey = targetKey
        end

        local frame = win:frame()
        local mouse = hs.mouse.absolutePosition()

        -- Detect the left vertical tab sidebar
        
local inSidebar

	
-- Dynamic Accessibility detection for supported browsers



if bundleID == "com.microsoft.edgemac" then

    -- Edge: webpage-boundary detection
    inSidebar = isInEdgeTabs(mouse, frame, targetKey)


elseif bundleID == "com.google.Chrome" then

    -- Precise detection for vertical tabs
    inSidebar = isInChromeTabs(mouse)

    -- Probe Chrome's left sidebar to determine
    -- whether vertical tabs are currently enabled.
    local verticalProbe = {
        x = frame.x + 20,
        y = frame.y + math.min(180, frame.h * 0.35)
    }

    -- Only use horizontal detection if Chrome
    -- does NOT have a vertical tab sidebar.
    if not inSidebar
        and mouse.y >= frame.y
        and mouse.y < frame.y + 55
        and not isInChromeTabs(verticalProbe) then

        inSidebar = isInBraveSidebar(mouse, frame, targetKey)
    end


elseif bundleID == "org.mozilla.firefox" then

    -- Firefox's native horizontal/vertical AXTabGroup
    inSidebar = isInFirefoxTabs(mouse, frame)

    -- Probe the top tab strip to determine whether
    -- Firefox is using horizontal tabs.
    local horizontalProbe = {
        x = frame.x + math.min(200, frame.w * 0.5),
        y = frame.y + 20
    }

    -- Only use the original vertical-tab fallback
    -- if horizontal tabs are NOT detected.
    if not inSidebar
        and mouse.y >= frame.y + 55
        and not isInFirefoxTabs(horizontalProbe, frame) then

        inSidebar = isInBraveSidebar(mouse, frame, targetKey)
    end

else

    -- Brave: preserve the existing working method
    inSidebar = isInBraveSidebar(mouse, frame, targetKey)

end

        if not inSidebar then
            accumulated = 0
            return false
        end

        -- Ignore trackpad momentum after fingers are lifted
        local momentum = event:getProperty(
            props.scrollWheelEventMomentumPhase
        ) or 0

        if momentum ~= 0 then return true end

        local continuous = event:getProperty(
            props.scrollWheelEventIsContinuous
        )

        local delta

        if continuous ~= 0 then
            delta = event:getProperty(
                props.scrollWheelEventPointDeltaAxis1
            )
        else
            delta = event:getProperty(
                props.scrollWheelEventDeltaAxis1
            )
        end

        if not delta or delta == 0 then
            return true
        end

        local now = hs.timer.secondsSinceEpoch()
        local direction = delta > 0 and 1 or -1

        -- Reset when a new gesture begins
        if now - lastEventTime > 0.3
            or direction ~= lastDirection then
            accumulated = 0
        end

        lastEventTime = now
        lastDirection = direction

        -- Mouse wheel: one notch switches one tab
        -- Trackpad: accumulate smooth scrolling
        local threshold = continuous ~= 0
            and config.sensitivity or 1

        accumulated = accumulated + math.abs(delta)

        if accumulated >= threshold
            and now - lastSwitchTime >= config.cooldown then

            accumulated = 0
            lastSwitchTime = now
            switchTab(direction, appPID, windowID)
        end

        -- Prevent the tab sidebar itself from scrolling
        return true
    end
)

verticalTabScroll:start()
hs.alert.show("Browser tab scrolling enabled!")
