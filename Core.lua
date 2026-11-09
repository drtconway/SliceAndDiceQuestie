-- SliceAndDiceQuestie: settings, events and slash commands.
local ADDON, ns = ...
_G.SliceAndDiceQuestie = ns -- for /dump debugging

local DEFAULTS = {
    autoLevel = true,     -- level range follows the character's level
    lo = 1,
    hi = 10,
    hideDone = true,      -- hide chains whose in-range quests are all completed
    chainsOnly = false,   -- hide quests that are not part of a chain
    byReq = true,         -- also match quests whose required level is in range
    dungeons = false,     -- include dungeon quests
    classQuests = true,   -- include class quests (only your own class's are ever listed)
    wholeChain = true,    -- show chain steps outside the level range
    showDone = true,      -- show completed steps inside listed chains
    search = "",
    collapsed = {},
}

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SliceAndDiceQuestie|r: " .. tostring(msg))
end

function ns.MaxLevel()
    return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

function ns.PlayerLevel()
    return math.max(UnitLevel("player") or 1, ns.levelOverride or 0)
end

function ns.AutoRange(db)
    local pl = ns.PlayerLevel()
    db.lo = math.max(1, pl - 2)
    db.hi = math.min(ns.MaxLevel(), pl + 2)
end

function ns.IsReady()
    return type(Questie) == "table" and Questie.started and type(_G.LibQuestieDB) == "table"
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        SliceAndDiceQuestieDB = SliceAndDiceQuestieDB or {}
        local db = SliceAndDiceQuestieDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then
                db[k] = (type(v) == "table") and {} or v
            end
        end
        ns.db = db
        for _, e in ipairs({ "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED", "PLAYER_LEVEL_UP" }) do
            pcall(self.RegisterEvent, self, e) -- not every event exists on every client
        end
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LEVEL_UP" then
        ns.levelOverride = tonumber(arg1) -- UnitLevel can lag behind this event
        ns.UI:RefreshSoon()
    else
        ns.UI:RefreshSoon()
    end
end)

SLASH_SLICEANDDICEQUESTIE1 = "/sdq"
SLASH_SLICEANDDICEQUESTIE2 = "/sliceanddice"
SlashCmdList["SLICEANDDICEQUESTIE"] = function(msg)
    msg = strlower(strtrim(msg or ""))
    if msg == "reset" then
        ns.db.pos, ns.db.size = nil, nil
        ns.UI:ResetPosition()
        ns.Print("Window position reset.")
    else
        ns.UI:Toggle()
    end
end
