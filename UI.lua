-- SliceAndDiceQuestie: the window.
local ADDON, ns = ...
local UI = {}
ns.UI = UI
local Data = ns.Data

local floor, min, max, format = math.floor, math.min, math.max, string.format

local ROW_H = 16
local LIST_TOP = -106
local LIST_BOTTOM = 30
local MAX_INDENT_STEPS = 8

local ICON = {
    done = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t",
    log = "|TInterface\\GossipFrame\\ActiveQuestIcon:12:12|t",
    avail = "|TInterface\\GossipFrame\\AvailableQuestIcon:12:12|t",
    locked = "|TInterface\\GossipFrame\\AvailableQuestIcon:12:12:0:0:16:16:0:16:0:16:90:90:90|t",
}
local STATUS_TEXT = {
    done = "|cff40c040Completed|r",
    log = "|cffffd100In your quest log|r",
    avail = "|cff40ff40Available now|r",
    locked = "|cff999999Not available yet|r",
}

local frame, scroll, statusText
local rows, display = {}, {}
local checks = {}

local function Hex(r, g, b)
    return format("|cff%02x%02x%02x", floor(r * 255), floor(g * 255), floor(b * 255))
end

local function LevelColor(level, playerLevel)
    if not level or level <= 0 then return 1, 1, 1 end
    local d = level - playerLevel
    if d >= 5 then return 1, 0.1, 0.1 end
    if d >= 3 then return 1, 0.5, 0.25 end
    if d >= -2 then return 1, 0.82, 0 end
    local ok, green = pcall(GetQuestGreenRange, "player")
    if not ok or type(green) ~= "number" then green = 8 end
    if -d <= green then return 0.25, 0.75, 0.25 end
    return 0.5, 0.5, 0.5
end

local function ShortXP(xp)
    if not xp or xp <= 0 then return "" end
    if xp >= 10000 then return format("%.1fk xp", xp / 1000) end
    return format("%d xp", xp)
end

---------------------------------------------------------------------------
-- Display list
---------------------------------------------------------------------------

local function Options()
    local db = ns.db
    return {
        lo = db.lo, hi = db.hi, byReq = db.byReq, dungeons = db.dungeons, classQuests = db.classQuests,
        chainsOnly = db.chainsOnly, hideDone = db.hideDone, search = db.search,
    }
end

local function QuestLine(id, entry, pl)
    local q = Data.quests[id]
    local st = entry.status[id]
    local r, g, b
    if st == "done" then
        r, g, b = 0.45, 0.45, 0.45
    elseif not entry.matched[id] then
        r, g, b = 0.6, 0.6, 0.6
    else
        r, g, b = LevelColor(q.lvl, pl)
    end
    local text = ICON[st] .. " " .. Hex(r, g, b) .. "[" .. (q.lvl > 0 and q.lvl or "?") .. "] " .. q.name .. "|r"
    if q.dungeon then text = text .. " |cff7fbfff(dungeon)|r" end
    if q.classes ~= 0 then text = text .. " |cffc0a0ff(class)|r" end
    if st ~= "done" and q.rl > pl then text = text .. " |cffff6060(needs " .. q.rl .. ")|r" end
    local right = ""
    if st ~= "done" then right = ShortXP(Data:XP(id)) end
    return text, right
end

function UI:BuildDisplay()
    local db = ns.db
    local pl = ns.PlayerLevel()
    local groups, totals = Data:Query(Options(), pl)
    wipe(display)

    for _, g in ipairs(groups) do
        local zkey = "z" .. tostring(g.key)
        local zc = db.collapsed[zkey]
        local summary = (g.nChains > 0) and format("%d chain%s, ", g.nChains, g.nChains == 1 and "" or "s") or ""
        display[#display + 1] = {
            kind = "zone", key = zkey,
            text = "|cffffd100" .. (zc and "[+] " or "[-] ") .. g.name .. "|r",
            right = "|cff909090" .. summary .. g.open .. " to do  " .. ShortXP(g.xp) .. "|r",
        }
        if not zc then
            for _, entry in ipairs(g.chains) do
                local comp = entry.comp
                local base, skip = 0, false
                if comp.size > 1 then
                    local ckey = "c" .. comp.members[1]
                    local cc = db.collapsed[ckey]
                    local first = Data.quests[comp.members[1]]
                    display[#display + 1] = {
                        kind = "chain", key = ckey, indent = 10,
                        text = "|cffd8d8d8" .. (cc and "[+] " or "[-] ") .. first.name .. "|r |cff808080- "
                            .. comp.size .. " quests, levels " .. (entry.minL or "?") .. "-" .. (entry.maxL or "?") .. "|r",
                        right = "|cff909090" .. ShortXP(entry.xp) .. "|r",
                    }
                    base, skip = 1, cc
                end
                if not skip then
                    for _, id in ipairs(comp.members) do
                        local st = entry.status[id]
                        if (db.wholeChain or entry.matched[id]) and (db.showDone or st ~= "done") then
                            local text, right = QuestLine(id, entry, pl)
                            local steps = base + min(comp.depth[id] or 0, MAX_INDENT_STEPS)
                            display[#display + 1] = {
                                kind = "quest", id = id, entry = entry,
                                indent = 10 + steps * 12, text = text, right = right,
                            }
                        end
                    end
                end
            end
        end
    end

    if #display == 0 then
        display[1] = { kind = "empty", text = "|cff999999Nothing matches. Try widening the level range or ticking more boxes.|r" }
    end
    statusText:SetText(format("%d chains, %d quests to do, about %s at your level",
        totals.chains, totals.quests, totals.xp > 0 and ShortXP(totals.xp) or "0 xp"))
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function QuestTooltip(row, id, entry)
    local q = Data.quests[id]
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(q.name, 1, 0.82, 0)
    GameTooltip:AddLine(format("Quest %d  -  level %d, requires %d", id, q.ql, q.rl), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(STATUS_TEXT[entry.status[id]] or "")
    GameTooltip:AddLine("Zone: " .. Data.ZoneName(q.zone), 0.8, 0.8, 0.8)
    for _, s in ipairs(Data:Who(id, "startedBy")) do GameTooltip:AddLine("Starts: " .. s, 0.6, 0.9, 1) end
    for _, s in ipairs(Data:Who(id, "finishedBy")) do GameTooltip:AddLine("Ends: " .. s, 0.6, 0.9, 1) end
    local objectives = Data:Objectives(id)
    for i = 1, min(#objectives, 3) do
        GameTooltip:AddLine(objectives[i], 1, 1, 1, true)
    end
    if entry.status[id] == "locked" then
        local missing = Data:MissingPrereqs(id)
        if #missing > 0 then
            GameTooltip:AddLine("Needs first: " .. table.concat(missing, ", "), 1, 0.4, 0.4, true)
        end
    end
    local xp = Data:XP(id)
    if xp > 0 then GameTooltip:AddLine(format("XP at your level: %d", xp), 0.6, 1, 0.6) end
    GameTooltip:Show()
end

local function RowOnClick(row)
    local item = row.item
    if item and (item.kind == "zone" or item.kind == "chain") then
        ns.db.collapsed[item.key] = (not ns.db.collapsed[item.key]) or nil
        UI:Refresh()
    end
end

local function CreateRow(i)
    local row = CreateFrame("Button", nil, frame)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.right:SetJustifyH("RIGHT")
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", RowOnClick)
    row:SetScript("OnEnter", function(self)
        if self.item and self.item.kind == "quest" then QuestTooltip(self, self.item.id, self.item.entry) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

function UI:UpdateRows()
    if not frame then return end
    local visible = max(1, floor(scroll:GetHeight() / ROW_H))
    for i = #rows + 1, visible do rows[i] = CreateRow(i) end
    FauxScrollFrame_Update(scroll, #display, visible, ROW_H)
    local offset = FauxScrollFrame_GetOffset(scroll)
    local maxOffset = max(0, #display - visible)
    if offset > maxOffset then
        -- The list got shorter (filter change): pull the scroll position back into range.
        offset = maxOffset
        FauxScrollFrame_SetOffset(scroll, offset)
        local bar = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
        if bar then bar:SetValue(offset * ROW_H) end
    end
    for i, row in ipairs(rows) do
        local item = (i <= visible) and display[offset + i]
        row.item = item
        if item then
            row.text:SetFontObject(item.kind == "zone" and "GameFontNormal" or "GameFontHighlightSmall")
            row.text:ClearAllPoints()
            row.text:SetPoint("LEFT", row, "LEFT", 4 + (item.indent or 0), 0)
            row.text:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
            row.text:SetText(item.text)
            row.right:SetText(item.right or "")
            row:Show()
        else
            row:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------

local function Tooltip(widget, title, body)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateCheck(label, key, x, y, tip)
    local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 1, 1)
    fs:SetText(label)
    cb:SetHitRectInsets(0, -(fs:GetStringWidth() + 4), 0, 0)
    cb:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() and true or false
        UI:Refresh()
    end)
    Tooltip(cb, label, tip)
    cb.key = key
    checks[#checks + 1] = cb
    return cb
end

local function CreateButton(text, width, x, y, onClick, tip)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    if tip then Tooltip(b, text, tip) end
    return b
end

local function CreateLevelBox(x, y)
    local eb = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    eb:SetSize(26, 20)
    eb:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(2)
    eb:SetJustifyH("CENTER")
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEditFocusLost", function() UI:ApplyLevels() end)
    return eb
end

function UI:ApplyLevels()
    local db = ns.db
    local lo, hi = tonumber(self.loBox:GetText()), tonumber(self.hiBox:GetText())
    if not lo or not hi then self:Refresh(); return end
    lo = max(1, min(ns.MaxLevel(), lo))
    hi = max(1, min(ns.MaxLevel(), hi))
    if lo > hi then lo, hi = hi, lo end
    if lo ~= db.lo or hi ~= db.hi then
        db.lo, db.hi, db.autoLevel = lo, hi, false
    end
    self:Refresh()
end

function UI:ShiftLevels(delta)
    local db = ns.db
    local width = db.hi - db.lo
    local lo = max(1, min(ns.MaxLevel() - width, db.lo + delta))
    db.lo, db.hi, db.autoLevel = lo, lo + width, false
    self:Refresh()
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    ns.db.pos = { point, relPoint, x, y }
    ns.db.size = { frame:GetWidth(), frame:GetHeight() }
end

function UI:ResetPosition()
    if not frame then return end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    frame:SetSize(620, 560)
end

function UI:Create()
    if frame then return end
    local ok, f = pcall(CreateFrame, "Frame", "SliceAndDiceQuestieFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "SliceAndDiceQuestieFrame", UIParent, "BackdropTemplate")
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32, insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    frame = f
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(560, 360, 1200, 1400)
    elseif frame.SetMinResize then
        frame:SetMinResize(560, 360)
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    tinsert(UISpecialFrames, "SliceAndDiceQuestieFrame")

    local db = ns.db
    frame:ClearAllPoints()
    if db.pos then
        frame:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
    else
        frame:SetPoint("CENTER")
    end
    if db.size then frame:SetSize(db.size[1], db.size[2]) else frame:SetSize(620, 560) end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", frame, "TOP", 0, -5)
    title:SetText("SliceAndDiceQuestie")

    -- Row 1: level range and search
    local lvl = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    lvl:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -36)
    lvl:SetText("Levels")
    self.loBox = CreateLevelBox(64, -31)
    local to = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    to:SetPoint("LEFT", self.loBox, "RIGHT", 4, 0)
    to:SetText("to")
    self.hiBox = CreateLevelBox(110, -31)
    CreateButton("<", 24, 142, -31, function() UI:ShiftLevels(-1) end, "Move the range down one level.")
    CreateButton(">", 24, 168, -31, function() UI:ShiftLevels(1) end, "Move the range up one level.")
    CreateButton("My level", 72, 198, -31, function()
        ns.db.autoLevel = true
        UI:Refresh()
    end, "Set the range to your level minus 2 up to plus 2, and keep it following you as you level.")

    local search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -31)
    search:SetAutoFocus(false)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            ns.db.search = self:GetText()
            UI:Refresh()
        end
    end)
    self.searchBox = search
    local sl = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    sl:SetPoint("RIGHT", search, "LEFT", -8, 0)
    sl:SetText("Search")

    -- Rows 2 and 3: filters
    CreateCheck("Hide finished chains", "hideDone", 12, -56,
        "Hide chains where you have completed every quest in the level range.")
    CreateCheck("Chains only", "chainsOnly", 170, -56,
        "Hide quests that are not part of a chain.")
    CreateCheck("Match required level", "byReq", 290, -56,
        "Also list quests whose required level is in the range, even if their quest level is above it "
        .. "(for example Hammerfall: quest level 34, can be picked up at 29).")
    CreateCheck("Whole chain", "wholeChain", 450, -56,
        "Show every step of a listed chain, including steps outside the level range (shown dimmed).")
    CreateCheck("Dungeon quests", "dungeons", 12, -78,
        "Include quests that are done inside a dungeon.")
    CreateCheck("Class quests", "classQuests", 170, -78,
        "Include class quests. Only quests for your own class are ever listed.")
    CreateCheck("Show completed steps", "showDone", 290, -78,
        "Show the steps you have already completed in listed chains, ticked and greyed out.")

    -- List
    scroll = CreateFrame("ScrollFrame", "SliceAndDiceQuestieScroll", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, LIST_BOTTOM)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() UI:UpdateRows() end)
    end)

    -- Footer
    statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 11)
    local legend = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    legend:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, 11)
    legend:SetText(ICON.avail .. " available  " .. ICON.log .. " in log  " .. ICON.done .. " done  "
        .. ICON.locked .. " locked")

    -- Resize grip
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); SavePosition(); UI:UpdateRows() end)
    frame:SetScript("OnSizeChanged", function() UI:UpdateRows() end)

    frame:SetScript("OnShow", function() UI:Refresh() end)
    frame:Hide()
end

function UI:Refresh()
    if not frame or not frame:IsShown() then return end
    local db = ns.db
    if db.autoLevel then ns.AutoRange(db) end
    if not self.loBox:HasFocus() then self.loBox:SetText(tostring(db.lo)) end
    if not self.hiBox:HasFocus() then self.hiBox:SetText(tostring(db.hi)) end
    if not self.searchBox:HasFocus() then self.searchBox:SetText(db.search or "") end
    for _, cb in ipairs(checks) do cb:SetChecked(db[cb.key] and true or false) end
    self:BuildDisplay()
    self:UpdateRows()
end

local refreshPending = false
function UI:RefreshSoon()
    if not frame or not frame:IsShown() or refreshPending then return end
    refreshPending = true
    C_Timer.After(1, function()
        refreshPending = false
        UI:Refresh()
    end)
end

function UI:Toggle()
    if not ns.IsReady() then
        ns.Print("Questie is still loading. Try again in a few seconds.")
        return
    end
    if not Data.quests then
        local started = debugprofilestop and debugprofilestop()
        local okCall, ok, err = pcall(Data.Build, Data)
        if not okCall or not ok then
            Data.quests = nil
            ns.Print("Could not read the quest database: " .. tostring(okCall and err or ok))
            return
        end
        if started then
            local n = 0
            for _ in pairs(Data.quests) do n = n + 1 end
            ns.Print(format("Scanned %d quests in %.1f s.", n, (debugprofilestop() - started) / 1000))
        end
    end
    self:Create()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end
