-- SliceAndDiceQuestie: reads QuestieDB, builds quest chains, and filters them.
local ADDON, ns = ...
local Data = {}
ns.Data = Data

local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local pairs, ipairs, type, tonumber, format = pairs, ipairs, type, tonumber, string.format
local strlower, strfind, tremove, tsort = string.lower, string.find, table.remove, table.sort

local function Import(name)
    if QuestieLoader and QuestieLoader.ImportModule then
        return QuestieLoader:ImportModule(name)
    end
end
Data.Import = Import

-- Race and class masks go past 32 bits, so test bits arithmetically rather than with bit.band.
local function HasBit(mask, index)
    if not mask or mask == 0 or not index or index < 1 then return true end
    return floor(mask / 2 ^ (index - 1)) % 2 == 1
end

-- Fields read once per quest, in this order.
local FIELDS = { "name", "questLevel", "requiredLevel", "requiredRaces", "requiredClasses", "zoneOrSort",
    "preQuestSingle", "preQuestGroup", "nextQuestInChain", "breadcrumbForQuestId", "childQuests",
    "parentQuest", "specialFlags" }

local BATTLEGROUNDS = { [2597] = true, [3277] = true, [3358] = true } -- AV, WSG, AB
local SORT_BATTLEGROUNDS = -25

local SORT_NAMES = {
    [-1] = "Epic", [-22] = "Seasonal", [-24] = "Herbalism", [-25] = "Battlegrounds",
    [-61] = "Warlock", [-81] = "Warrior", [-82] = "Shaman", [-101] = "Fishing",
    [-121] = "Blacksmithing", [-141] = "Paladin", [-161] = "Mage", [-162] = "Rogue",
    [-181] = "Alchemy", [-182] = "Leatherworking", [-201] = "Engineering", [-221] = "Treasure Map",
    [-261] = "Hunter", [-262] = "Priest", [-263] = "Druid", [-264] = "Tailoring",
    [-284] = "Special", [-304] = "Cooking", [-324] = "First Aid", [-344] = "Legendary",
    [-364] = "Darkmoon Faire", [-365] = "Ahn'Qiraj War Effort", [-366] = "Lunar Festival",
    [-367] = "Reputation", [-368] = "Invasion", [-369] = "Midsummer", [-370] = "Brewfest",
}

-- Class ID (from UnitClass) to its quest sort, so class quests zoned to a city group under the class name.
local CLASS_SORT_BY_ID = {
    [1] = -81, [2] = -141, [3] = -261, [4] = -162, [5] = -262, [7] = -82, [8] = -161, [9] = -61, [11] = -263,
}
local CLASS_PROF_SORTS = {
    [-61] = true, [-81] = true, [-82] = true, [-141] = true, [-161] = true, [-162] = true,
    [-261] = true, [-262] = true, [-263] = true,                                   -- classes
    [-24] = true, [-101] = true, [-121] = true, [-181] = true, [-182] = true,
    [-201] = true, [-264] = true, [-304] = true, [-324] = true,                    -- professions
}

Data.BUCKET_CLASSPROF = "Class & Professions"
Data.BUCKET_OTHER = "Other"

local function IsJunkName(name)
    return strfind(name, "UNUSED", 1, true) or strfind(name, "DEPRECATED", 1, true)
        or strfind(name, "[PH]", 1, true) or strfind(name, "^zz")
end

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------

local fallbackZoneNames
local function FallbackZoneNames()
    local names = {}
    local l10n = Import("l10n")
    if l10n and type(l10n.zoneLookup) == "table" then
        for _, zones in pairs(l10n.zoneLookup) do
            if type(zones) == "table" then
                for id, name in pairs(zones) do
                    if type(name) == "string" and names[id] == nil then names[id] = name end
                end
            end
        end
    end
    return names
end

function Data.ZoneName(zone)
    zone = tonumber(zone)
    if not zone or zone == 0 then return "Unknown" end
    if zone < 0 then return SORT_NAMES[zone] or ("Other (" .. zone .. ")") end
    local name = C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(zone)
    if name and name ~= "" then return name end
    fallbackZoneNames = fallbackZoneNames or FallbackZoneNames()
    return fallbackZoneNames[zone] or ("Area " .. zone)
end

local function IsDungeon(zone)
    if not zone or zone <= 0 then return false end
    local ZoneDB = Import("ZoneDB")
    if ZoneDB and ZoneDB.IsDungeonZone then
        local ok, res = pcall(ZoneDB.IsDungeonZone, zone)
        return ok and res and true or false
    end
    return false
end

-- Subzones are grouped under their parent zone; dungeons keep their own name.
local function GroupKey(zone, dungeon)
    if not zone or zone <= 0 or dungeon then return zone or 0 end
    local ZoneDB = Import("ZoneDB")
    if ZoneDB and ZoneDB.GetParentZoneId then
        local ok, parent = pcall(ZoneDB.GetParentZoneId, ZoneDB, zone)
        if ok and type(parent) == "number" and parent > 0 then return parent end
    end
    return zone
end

-- Continent name for a (parent) zone: walk the game's map tree up to the continent,
-- falling back to Questie's zone table, where map 0 is Eastern Kingdoms and map 1 is Kalimdor.
local continentCache = {}
local fallbackContinentByArea

local function FallbackContinent(areaId)
    if not fallbackContinentByArea then
        fallbackContinentByArea = {}
        local l10n = Import("l10n")
        local names = { [0] = "Eastern Kingdoms", [1] = "Kalimdor" }
        if l10n and type(l10n.zoneLookup) == "table" then
            for mapId, continent in pairs(names) do
                local zones = l10n.zoneLookup[mapId]
                if type(zones) == "table" then
                    for id in pairs(zones) do fallbackContinentByArea[id] = continent end
                end
            end
        end
    end
    return fallbackContinentByArea[areaId]
end

local function ContinentOf(areaId)
    local cached = continentCache[areaId]
    if cached then return cached end
    local name
    local ZoneDB = Import("ZoneDB")
    if ZoneDB and ZoneDB.GetUiMapIdByAreaId and C_Map and C_Map.GetMapInfo then
        local ok, uiMapId = pcall(ZoneDB.GetUiMapIdByAreaId, ZoneDB, areaId)
        local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
        local info = ok and uiMapId and C_Map.GetMapInfo(uiMapId)
        local guard = 0
        while info and guard < 10 do
            if info.mapType == continentType then name = info.name; break end
            if not info.parentMapID or info.parentMapID == 0 then break end
            info = C_Map.GetMapInfo(info.parentMapID)
            guard = guard + 1
        end
    end
    name = name or FallbackContinent(areaId) or Data.BUCKET_OTHER
    continentCache[areaId] = name
    return name
end

-- Top-level bucket and the group key inside it for one quest.
local function Bucket(zone, group, classes, classId)
    if classes ~= 0 or CLASS_PROF_SORTS[zone] then
        return Data.BUCKET_CLASSPROF, (zone < 0) and zone or (CLASS_SORT_BY_ID[classId] or group)
    elseif zone <= 0 then
        return Data.BUCKET_OTHER, zone
    end
    return ContinentOf(group), group
end

---------------------------------------------------------------------------
-- Building the chain graph (once per session)
---------------------------------------------------------------------------

local function EachId(list, fn)
    if type(list) == "number" then
        fn(list)
    elseif type(list) == "table" then
        for _, x in ipairs(list) do
            x = tonumber(x)
            if x then fn(x) end
        end
    end
end

local function OrderComponent(members, quests, succ, pred)
    local function Before(a, b)
        local la, lb = quests[a].lvl, quests[b].lvl
        if la ~= lb then return la < lb end
        return a < b
    end

    local inSet, indeg, placed = {}, {}, {}
    for _, x in ipairs(members) do inSet[x] = true; indeg[x] = 0 end
    for _, x in ipairs(members) do
        if succ[x] then
            for y in pairs(succ[x]) do
                if inSet[y] then indeg[y] = indeg[y] + 1 end
            end
        end
    end

    local ready, order = {}, {}
    for _, x in ipairs(members) do
        if indeg[x] == 0 then ready[#ready + 1] = x end
    end
    while true do
        if #ready == 0 then
            -- Either finished, or a cycle in the data: take the lowest unplaced quest.
            local best
            for _, x in ipairs(members) do
                if not placed[x] and (not best or Before(x, best)) then best = x end
            end
            if not best then break end
            ready[1] = best
        end
        local bi = 1
        for i = 2, #ready do
            if Before(ready[i], ready[bi]) then bi = i end
        end
        local x = tremove(ready, bi)
        if not placed[x] then
            placed[x] = true
            order[#order + 1] = x
            if succ[x] then
                for y in pairs(succ[x]) do
                    if inSet[y] and not placed[y] then
                        indeg[y] = indeg[y] - 1
                        if indeg[y] == 0 then ready[#ready + 1] = y end
                    end
                end
            end
        end
    end

    local depth = {}
    for _, x in ipairs(order) do
        local d = 0
        if pred[x] then
            for p in pairs(pred[x]) do
                if inSet[p] and depth[p] and depth[p] + 1 > d then d = depth[p] + 1 end
            end
        end
        depth[x] = d
    end
    return { members = order, depth = depth, size = #order }
end

function Data:Build()
    if self.quests then return true end
    local LQ = _G.LibQuestieDB
    if not (LQ and LQ.Quest and LQ.Quest.GetAll and LQ.Quest.GetAllIds) then
        return false, "QuestieDB is not loaded."
    end
    if LQ.RequireContract then
        local ok, msg = LQ.RequireContract(4)
        if not ok then return false, msg end
    end

    local corrections = Import("QuestieCorrections")
    local hidden = (corrections and type(corrections.hiddenQuests) == "table") and corrections.hiddenQuests or {}
    local _, _, raceId = UnitRace("player")
    local _, _, classId = UnitClass("player")

    local quests, raw = {}, {}
    for _, id in ipairs(LQ.Quest.GetAllIds()) do
        if not hidden[id] then
            local v = LQ.Quest.GetAll(id, FIELDS)
            local name = v and v[1]
            if type(name) == "string" and name ~= "" and not IsJunkName(name) then
                local races, classes = tonumber(v[4]) or 0, tonumber(v[5]) or 0
                local zone, flags = tonumber(v[6]) or 0, tonumber(v[13]) or 0
                local repeatable = flags % 2 == 1
                if HasBit(races, raceId) and HasBit(classes, classId) and not repeatable
                    and not BATTLEGROUNDS[zone] and zone ~= SORT_BATTLEGROUNDS then
                    local ql, rl = tonumber(v[2]) or 0, tonumber(v[3]) or 0
                    local dungeon = IsDungeon(zone)
                    local group = GroupKey(zone, dungeon)
                    local bucket, gkey = Bucket(zone, group, classes, classId)
                    quests[id] = {
                        id = id, name = name, ql = ql, rl = rl, lvl = (ql > 0) and ql or rl,
                        classes = classes, zone = zone, dungeon = dungeon, bucket = bucket, gkey = gkey,
                    }
                    raw[id] = v
                end
            end
        end
    end

    local succ, pred, adj = {}, {}, {}
    local function Link(a, b)
        if not a or not b or a == b or not quests[a] or not quests[b] then return end
        succ[a] = succ[a] or {}; succ[a][b] = true
        pred[b] = pred[b] or {}; pred[b][a] = true
        adj[a] = adj[a] or {}; adj[a][b] = true
        adj[b] = adj[b] or {}; adj[b][a] = true
    end
    for id, v in pairs(raw) do
        EachId(v[7], function(p) Link(p, id) end)        -- preQuestSingle
        EachId(v[8], function(p) Link(abs(p), id) end)   -- preQuestGroup
        EachId(v[9], function(n) Link(id, n) end)        -- nextQuestInChain
        EachId(v[10], function(b) Link(id, b) end)       -- breadcrumbForQuestId
        EachId(v[11], function(c) Link(id, c) end)       -- childQuests
        EachId(v[12], function(p) Link(p, id) end)       -- parentQuest
    end

    local comps, seen = {}, {}
    for id in pairs(quests) do
        if not seen[id] then
            local members, stack = {}, { id }
            seen[id] = true
            while #stack > 0 do
                local x = tremove(stack)
                members[#members + 1] = x
                if adj[x] then
                    for y in pairs(adj[x]) do
                        if not seen[y] then seen[y] = true; stack[#stack + 1] = y end
                    end
                end
            end
            local comp = OrderComponent(members, quests, succ, pred)
            comps[#comps + 1] = comp
            for _, x in ipairs(comp.members) do quests[x].comp = comp end
        end
    end

    self.quests, self.comps, self.pred, self.succ = quests, comps, pred, succ
    return true
end

---------------------------------------------------------------------------
-- Character state
---------------------------------------------------------------------------

function Data:IsComplete(id)
    local t = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
    if t then return t[id] and true or false end
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        return C_QuestLog.IsQuestFlaggedCompleted(id) and true or false
    end
    if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(id) and true or false end
    return false
end

function Data:IsInLog(id)
    local AQ = Import("ActiveQuests")
    if AQ and AQ.Get then
        local ok, r = pcall(AQ.Get, id)
        if ok then return r and true or false end
    end
    if GetQuestLogIndexByID then
        local i = GetQuestLogIndexByID(id)
        return i ~= nil and i > 0
    end
    return false
end

function Data:IsAvailable(id, playerLevel)
    local q = self.quests[id]
    if not q or q.rl > playerLevel then return false end
    local QDB = Import("QuestieDB")
    if QDB and QDB.IsDoable then
        local ok, r = pcall(QDB.IsDoable, id)
        if ok then return r and true or false end
    end
    return true
end

-- "done" | "log" | "avail" | "locked"
function Data:Status(id, playerLevel)
    if self:IsComplete(id) then return "done" end
    if self:IsInLog(id) then return "log" end
    if self:IsAvailable(id, playerLevel) then return "avail" end
    return "locked"
end

function Data:XP(id)
    local QXP = Import("QuestXP")
    if QXP and QXP.GetQuestLogRewardXP then
        local ok, xp = pcall(QXP.GetQuestLogRewardXP, QXP, id)
        if ok and type(xp) == "number" then return xp end
    end
    return 0
end

---------------------------------------------------------------------------
-- Details for tooltips
---------------------------------------------------------------------------

local function Place(spawns)
    if type(spawns) ~= "table" then return nil end
    for zone, list in pairs(spawns) do
        local c = type(list) == "table" and list[1]
        if type(c) == "table" and tonumber(c[1]) and c[1] >= 0 then
            return format("%s (%.1f, %.1f)", Data.ZoneName(zone), c[1], tonumber(c[2]) or 0)
        end
    end
    for zone in pairs(spawns) do return Data.ZoneName(zone) .. " (inside)" end
end

-- Returns up to 3 "Name - Zone (x, y)" strings for a quest's startedBy or finishedBy field.
function Data:Who(id, field)
    local LQ = _G.LibQuestieDB
    local v = LQ.Quest.Get(id, field)
    local out = {}
    if type(v) ~= "table" then return out end
    local function Add(list, entity, kind)
        if type(list) ~= "table" then return end
        for _, eid in ipairs(list) do
            if #out >= 3 then return end
            local name = (entity and entity.Get(eid, "name")) or (kind .. " " .. eid)
            if kind == "item" then
                out[#out + 1] = name .. " (item)"
            else
                local where = entity and Place(entity.Get(eid, "spawns"))
                out[#out + 1] = where and (name .. " - " .. where) or name
            end
        end
    end
    Add(v[1], LQ.Npc, "npc")
    Add(v[2], LQ.Object, "object")
    Add(v[3], LQ.Item, "item")
    return out
end

function Data:Objectives(id)
    local t = _G.LibQuestieDB.Quest.Get(id, "objectivesText")
    return type(t) == "table" and t or {}
end

-- Prerequisites in the chain that are not yet completed.
function Data:MissingPrereqs(id)
    local out = {}
    if self.pred[id] then
        for p in pairs(self.pred[id]) do
            if not self:IsComplete(p) then out[#out + 1] = self.quests[p].name end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Filtering
---------------------------------------------------------------------------

-- o: lo, hi, byReq, dungeons, classQuests, chainsOnly, hideDone, search
function Data:Query(o, playerLevel)
    local quests = self.quests
    local hiddenByUser = (Questie and Questie.db and Questie.db.char and Questie.db.char.hidden) or {}
    local search = (o.search and o.search ~= "") and strlower(o.search) or nil
    local buckets, byBucket = {}, {}
    local totals = { chains = 0, quests = 0, xp = 0 }

    for _, comp in ipairs(self.comps) do
        if comp.size > 1 or not o.chainsOnly then
            local matched, open = nil, false
            local hit = not search
            for _, id in ipairs(comp.members) do
                local q = quests[id]
                if not hit and strfind(strlower(q.name), search, 1, true) then hit = true end
                if not hiddenByUser[id] and (o.dungeons or not q.dungeon) and (o.classQuests or q.classes == 0)
                    and ((q.lvl >= o.lo and q.lvl <= o.hi)
                        or (o.byReq and q.rl > 0 and q.rl >= o.lo and q.rl <= o.hi)) then
                    matched = matched or {}
                    matched[id] = true
                    if not open and not self:IsComplete(id) then open = true end
                end
            end

            if matched and hit and (open or not o.hideDone) then
                local entry = { comp = comp, matched = matched, status = {}, xp = 0, open = 0 }
                -- The chain goes in the bucket most of its in-range quests belong to,
                -- and under the most common group within that bucket.
                local bCounts, bucket, bN = {}, nil, 0
                for _, id in ipairs(comp.members) do
                    if matched[id] then
                        local b = quests[id].bucket
                        bCounts[b] = (bCounts[b] or 0) + 1
                        if bCounts[b] > bN then bucket, bN = b, bCounts[b] end
                    end
                end
                local counts, bestKey, bestN = {}, nil, 0
                for _, id in ipairs(comp.members) do
                    local q = quests[id]
                    local st = self:Status(id, playerLevel)
                    entry.status[id] = st
                    if q.lvl > 0 then
                        entry.minL = entry.minL and min(entry.minL, q.lvl) or q.lvl
                        entry.maxL = entry.maxL and max(entry.maxL, q.lvl) or q.lvl
                    end
                    if matched[id] then
                        entry.sortLevel = entry.sortLevel or q.lvl
                        if q.bucket == bucket then
                            local k = q.gkey
                            counts[k] = (counts[k] or 0) + 1
                            if counts[k] > bestN then bestKey, bestN = k, counts[k] end
                        end
                        if st ~= "done" then
                            entry.open = entry.open + 1
                            entry.xp = entry.xp + self:XP(id)
                        end
                    end
                end

                local bk = byBucket[bucket]
                if not bk then
                    bk = { name = bucket, groups = {}, byKey = {}, open = 0, xp = 0, nChains = 0 }
                    byBucket[bucket] = bk
                    buckets[#buckets + 1] = bk
                end
                local g = bk.byKey[bestKey]
                if not g then
                    g = { key = bestKey, name = Data.ZoneName(bestKey), chains = {}, open = 0, xp = 0, nChains = 0 }
                    bk.byKey[bestKey] = g
                    bk.groups[#bk.groups + 1] = g
                end
                g.chains[#g.chains + 1] = entry
                g.open, bk.open = g.open + entry.open, bk.open + entry.open
                g.xp, bk.xp = g.xp + entry.xp, bk.xp + entry.xp
                if comp.size > 1 then
                    g.nChains, bk.nChains = g.nChains + 1, bk.nChains + 1
                    totals.chains = totals.chains + 1
                end
                totals.quests = totals.quests + entry.open
                totals.xp = totals.xp + entry.xp
            end
        end
    end

    -- Eastern Kingdoms, Kalimdor, any other continent alphabetically, then Class & Professions, then Other.
    local function Rank(name)
        if name == "Eastern Kingdoms" then return 1 end
        if name == "Kalimdor" then return 2 end
        if name == Data.BUCKET_CLASSPROF then return 8 end
        if name == Data.BUCKET_OTHER then return 9 end
        return 3
    end
    tsort(buckets, function(a, b)
        local ra, rb = Rank(a.name), Rank(b.name)
        if ra ~= rb then return ra < rb end
        return a.name < b.name
    end)
    for _, bk in ipairs(buckets) do
        bk.byKey = nil
        tsort(bk.groups, function(a, b) return a.name < b.name end)
        for _, g in ipairs(bk.groups) do
            tsort(g.chains, function(a, b)
                local ca, cb = a.comp.size > 1, b.comp.size > 1
                if ca ~= cb then return ca end -- chains before single quests
                if (a.sortLevel or 0) ~= (b.sortLevel or 0) then return (a.sortLevel or 0) < (b.sortLevel or 0) end
                return quests[a.comp.members[1]].name < quests[b.comp.members[1]].name
            end)
        end
    end
    return buckets, totals
end
