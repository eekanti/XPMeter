-- XPMeter: session XP and gold tracker with start / pause / stop. Gold sources are described in the "gold" section.
--
-- The total comes from the XP bar itself (PLAYER_XP_UPDATE deltas, level-ups included), so nothing is missed.
-- It is split by source:
--   Kills        mob XP without the rested part ("X dies, you gain N experience.")
--   Rested bonus the "(+N exp Rested bonus)" part of kill XP
--   Quests       QUEST_TURNED_IN's xpReward
--   Exploration  "Discovered <area>: N experience gained"
--   Other        whatever the bar gained that none of the above explain (dungeon/profession/scripted XP, ...)
-- Quest turn-ins also print an unnamed "You gain N experience." line; it is ignored so quests aren't counted twice.
-- XP gained while paused or stopped is not counted, and only active (unpaused, online) time counts for XP/hr.
-- Styled through EllesmereUI's skinning API when it's installed; a plain flat dark look otherwise.

local ADDON = ...
local VERSION = "1.1.2"

local DEFAULTS = { shown = true, history = {}, collapsed = {} }
local db                                  -- XPMeterDB (per character)
local S                                   -- this session (db.s)
local activeSince                         -- GetTime() when the current running stretch began
local lastXP, lastMax                     -- XP bar baseline for deltas

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cFF8FB8FFXPMeter|r: " .. msg) end
-- /xpm debug: prints what the gold tracking sees (loot window, bags, item values)
local function D(...)
  if not (XPMeterDB and XPMeterDB.debug) then return end
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[i] = (issecretvalue and issecretvalue(v)) and "<secret>" or tostring(v)
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cFF8FB8FFXPMeter debug|r: " .. table.concat(parts, " "))
end

local function NewSession()
  return { state = "stopped", acc = 0, total = 0, kill = 0, rested = 0, quest = 0, explore = 0,
           kills = 0, quests = 0, discoveries = 0,
           -- gold, in copper: coin looted, quest money + reward items, looted items valued at the AH or a vendor
           gCoin = 0, gQuest = 0, gAH = 0, gVendor = 0, items = 0, loot = {} }
end
local function GoldTotal(s) return (s.gCoin or 0) + (s.gQuest or 0) + (s.gAH or 0) + (s.gVendor or 0) end

---------------------------------------------------------------- formatting
local function Commas(n)
  n = math.floor((n or 0) + 0.5)
  local s, neg = tostring(math.abs(n)), n < 0
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (neg and "-" or "") .. out
end
local function Short(n)
  n = n or 0
  if n >= 1e6 then return ("%.2fm"):format(n / 1e6) end
  if n >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  return Commas(n)
end
-- copper as "12g 34s 56c" with coin colors; short drops the copper (and silver) once there's gold
local function Money(c, short)
  c = math.floor((c or 0) + 0.5)
  local g, s, cu = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local G, S_, C = "|cFFFFD100%sg|r", "|cFFC7C7CF%ds|r", "|cFFEDA55F%dc|r"
  if g > 0 then
    if short and g >= 100 then return G:format(Commas(g)) end
    if short then return G:format(Commas(g)) .. " " .. S_:format(s) end
    return G:format(Commas(g)) .. " " .. S_:format(s) .. " " .. C:format(cu)
  end
  if s > 0 then return short and S_:format(s) or (S_:format(s) .. " " .. C:format(cu)) end
  return C:format(cu)
end
local function Clock(secs)
  secs = math.max(0, math.floor(secs or 0))
  return ("%d:%02d:%02d"):format(math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
end
local function Duration(secs)
  secs = math.floor(secs or 0)
  if secs < 60 then return "<1m" end
  local h, m = math.floor(secs / 3600), math.floor(secs / 60) % 60
  if h > 0 then return ("%dh %02dm"):format(h, m) end
  return m .. "m"
end

---------------------------------------------------------------- session accounting
local function Elapsed()
  if not S then return 0 end
  local e = S.acc or 0
  if S.state == "running" and activeSince then e = e + (GetTime() - activeSince) end
  return e
end
local function Running() return S and S.state == "running" end
local function Other()
  return math.max(0, S.total - S.kill - S.rested - S.quest - S.explore)
end
local function Rate()   -- XP per hour, nil until there's a minute of data
  local e = Elapsed()
  if e < 60 then return nil end
  return S.total / e * 3600
end
local function AtMaxLevel()
  local max = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion())
    or (GetMaxPlayerLevel and GetMaxPlayerLevel()) or MAX_PLAYER_LEVEL or 60
  return UnitLevel("player") >= max
end

local Refresh   -- the window, defined below

local function Start()
  if S.state == "running" then return end
  if S.state == "stopped" then db.s = NewSession(); S = db.s; S.started = time() end
  S.state = "running"; activeSince = GetTime()
  lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
  Refresh()
end
local function Pause()
  if S.state ~= "running" then return end
  S.acc = Elapsed(); activeSince = nil; S.state = "paused"
  Refresh()
end
local function Resume()
  if S.state ~= "paused" then return end
  S.state = "running"; activeSince = GetTime()
  Refresh()
end
local function Stop()
  if S.state == "stopped" then return end
  S.acc = Elapsed(); activeSince = nil; S.state = "stopped"; S.ended = time()
  local gold = GoldTotal(S)
  if S.total > 0 or gold > 0 then
    table.insert(db.history, 1, { started = S.started, ended = S.ended, secs = S.acc, total = S.total, kill = S.kill,
      rested = S.rested, quest = S.quest, explore = S.explore, other = Other(), kills = S.kills, quests = S.quests,
      gold = gold, gCoin = S.gCoin, gQuest = S.gQuest, gAH = S.gAH, gVendor = S.gVendor })
    while #db.history > 20 do table.remove(db.history) end
  end
  Print(("session stopped: %s XP and %s in %s (%s XP/hr, %s/hr)."):format(Commas(S.total), Money(gold), Clock(S.acc),
    S.acc >= 60 and Commas(S.total / S.acc * 3600) or "-", S.acc >= 60 and Money(gold / S.acc * 3600, true) or "-"))
  Refresh()
end
local function Reset()
  local was = S and S.state
  db.s = NewSession(); S = db.s; activeSince = nil
  if was == "running" or was == "paused" then S.started = time(); S.state = was; if was == "running" then activeSince = GetTime() end end
  lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
  Refresh()
end

---------------------------------------------------------------- reading XP from the game
-- turns a GlobalStrings format ("%s dies, you gain %d experience.") into a Lua pattern with captures
local function Pattern(fmt, anchorEnd, keepPeriod)
  if type(fmt) ~= "string" then return nil end
  local p = fmt:gsub("%%%d?%$?([sd])", "\001%1")             -- placeholders (incl. %1$s) out of the way
  p = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")            -- escape the rest
  p = p:gsub("\001s", "(.-)"):gsub("\001d", "([%%d,%%.]+)")
  if not keepPeriod then p = p:gsub("%%%.$", "") end         -- trailing period optional (bonus text follows it)
  return "^" .. p .. (anchorEnd and "$" or "")
end
local function Num(s) return tonumber((tostring(s or ""):gsub("[^%d]", ""))) end

local PAT = {}
local function BuildPatterns()
  PAT.kill = Pattern(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.")
  PAT.unnamed = Pattern(COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED or "You gain %d experience.")
  PAT.explore = Pattern(ERR_ZONE_EXPLORED_XP or "Discovered %s: %d experience gained")
  PAT.restedWord = ((TUTORIAL_TITLE26 or "Rested"):lower())
  PAT.coin = {}
  for _, c in ipairs({ { GOLD_AMOUNT or "%d Gold", 10000 }, { SILVER_AMOUNT or "%d Silver", 100 }, { COPPER_AMOUNT or "%d Copper", 1 } }) do
    local p = c[1]:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%d", "(%%d+)")
    PAT.coin[#PAT.coin + 1] = { p, c[2] }
  end
end

-- Forever marks some chat lines as "secret": reading them from addon code raises an error instead of
-- returning text. Those lines are skipped (their XP still lands in the total, under Other).
local function Readable(s)
  if issecretvalue and issecretvalue(s) then return false end
  return type(s) == "string"
end

local function OnCombatXP(text)
  if not Running() or not Readable(text) then return end
  if PAT.unnamed and text:match(PAT.unnamed) then return end   -- quest turn-in echo etc.: left to "Other"/"Quests"
  local _, xp = text:match(PAT.kill or "^(.-) dies, you gain ([%d,]+) experience")
  xp = Num(xp)
  if not xp or xp <= 0 then return end
  local rested = 0
  for sign, amount, label in text:gmatch("%(([%+%-])([%d,]+) exp ([^%)]*)%)") do
    label = label:lower()
    if sign == "+" and (label:find(PAT.restedWord, 1, true) or label:find("rested", 1, true)) then
      rested = rested + (Num(amount) or 0)
    end
  end
  rested = math.min(rested, xp)
  S.kill = S.kill + (xp - rested); S.rested = S.rested + rested; S.kills = S.kills + 1
end

local function OnSystem(text)
  if not Running() or not Readable(text) or not PAT.explore then return end
  local _, xp = text:match(PAT.explore)
  xp = Num(xp)
  if xp and xp > 0 then S.explore = S.explore + xp; S.discoveries = S.discoveries + 1 end
end

local questAt = -100   -- GetTime() of the last turn-in: reward items pushed right after it count as quest rewards
local function OnQuest(xpReward, moneyReward)
  if not Running() then return end
  questAt = GetTime()
  moneyReward = tonumber(moneyReward)
  if moneyReward and moneyReward > 0 then S.gQuest = S.gQuest + moneyReward end
  xpReward = tonumber(xpReward)
  if not xpReward or xpReward <= 0 or AtMaxLevel() then return end
  S.quest = S.quest + xpReward; S.quests = S.quests + 1
end

---------------------------------------------------------------- gold
-- Forever's loot chat lines can be secret (unreadable), so gold doesn't come from chat:
-- Coin: your money going up while a loot window is open (or up to 2 s after it closes). A party member's
--   coin share, which arrives without your loot window, comes from its chat line when that's readable.
-- Items: what's new in your bags while looting, valued once, when looted, at max(Auctionator's AH price,
--   vendor price); soulbound (bind on pickup) items can't be sold on the AH, so they only count their vendor price.
-- Quest rewards: QUEST_TURNED_IN's money, plus items new in your bags within 3 s of a turn-in.
-- Money from selling to vendors or the AH, mail and trades is NOT counted: the items were already counted
-- when looted, so counting the sale too would count them twice. Bag changes outside looting (buying, mail,
-- crafting, trades) aren't counted either.
local AUCTIONATOR_ID = "XPMeter"
local function AHPrice(link)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (api and api.GetAuctionPriceByItemLink) then return nil end
  local ok, p = pcall(api.GetAuctionPriceByItemLink, AUCTIONATOR_ID, link)
  return ok and tonumber(p) or nil
end
local function VendorPrice(link, sell)
  if sell and sell > 0 then return sell end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if api and api.GetVendorPriceByItemLink then
    local ok, p = pcall(api.GetVendorPriceByItemLink, AUCTIONATOR_ID, link)
    if ok and tonumber(p) then return tonumber(p) end
  end
  return 0
end

-- Forever's client has C_Item.GetItemInfo; the old global GetItemInfo may not exist there
local function ItemInfo(link)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not get then return nil end
  return get(link)
end

local pending = {}   -- items whose info wasn't cached yet: { link, count, quest, tries }
local function AddItem(link, count, quest, tries)
  if not Readable(link) then D("item link is secret, skipped"); return end
  local name, _, _, _, _, _, _, _, _, _, sell, _, _, bind = ItemInfo(link)
  if not name then
    D("item not cached yet, will retry:", link, "x" .. count)
    if (tries or 0) < 10 then pending[#pending + 1] = { link, count, quest, (tries or 0) + 1 } end
    return
  end
  local vendor = VendorPrice(link, sell)
  local ah = (bind ~= 1) and AHPrice(link) or nil      -- bind 1 = bind on pickup
  local each, src = vendor, "vendor"
  if ah and ah > vendor then each, src = ah, "ah" end
  local value = each * count
  if quest then S.gQuest = S.gQuest + value
  elseif src == "ah" then S.gAH = S.gAH + value
  else S.gVendor = S.gVendor + value end
  S.items = S.items + count
  local id = tonumber(link:match("item:(%d+)")) or link
  local e = S.loot[id] or { link = link, count = 0, value = 0 }
  e.count, e.value, e.src = e.count + count, e.value + value, quest and "quest" or src
  S.loot[id] = e
  D("counted", link, "x" .. count, "=", value, "copper (" .. (quest and "quest" or src) .. "; AH", ah, "vendor", vendor .. ")")
end
local function RetryPending()
  if #pending == 0 or not Running() then return end
  local list = pending; pending = {}
  for _, p in ipairs(list) do AddItem(p[1], p[2], p[3], p[4]) end
end

-- looting context: the loot window is open, or closed less than 2 s ago (bags and money update a moment later)
local lootOpen, lootClosedAt = false, -100
local function Looting() return lootOpen or GetTime() - lootClosedAt <= 2 end
local function QuestReward() return GetTime() - questAt <= 3 end

local lastMoney
local function OnPlayerMoney()
  local now = GetMoney()
  local d = lastMoney and (now - lastMoney) or 0
  lastMoney = now
  if d > 0 then
    D("money +" .. d, not Running() and "(session not running: not counted)"
      or (Looting() and "while looting: counted" or "not looting: ignored"))
  end
  if d > 0 and Running() and Looting() then S.gCoin = S.gCoin + d end
end

-- a party member looted coin and you got a share: no loot window of yours, so read the chat line if we can
local function OnMoneyChat(text)
  if not Running() or Looting() or not Readable(text) then return end
  local c = 0
  for _, unit in ipairs(PAT.coin) do
    local n = text:match(unit[1])
    if n then c = c + tonumber(n) * unit[2] end
  end
  if c > 0 then S.gCoin = S.gCoin + c end
end

-- bag contents: itemID -> { count, link }
local function BagCounts()
  local out = {}
  local C = C_Container
  local numSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, (numSlots and numSlots(bag)) or 0 do
      local id, n, link
      if C and C.GetContainerItemInfo then
        local info = C.GetContainerItemInfo(bag, slot)
        if info then id, n, link = info.itemID, info.stackCount, info.hyperlink end
      elseif GetContainerItemInfo then
        local _, count, _, _, _, _, l, _, _, itemID = GetContainerItemInfo(bag, slot)
        id, n, link = itemID, count, l
      end
      if id then
        local e = out[id]
        if e then e[1] = e[1] + (n or 1) else out[id] = { n or 1, link } end
      end
    end
  end
  return out
end
-- Looted items: the loot window is read when it opens, and each item is counted when there's proof you got
-- it: its slot being taken (LOOT_SLOT_CLEARED) or the item turning up in your bags, whichever comes first.
-- Forever doesn't reliably send the first one (or sends it after the window closes), so the bags back it up.
-- An item is never counted for more than the window held, so the two can't count it twice.
local lootSlots, expected = {}, {}   -- slot -> { id, qty };  itemID -> { link, qty, at }
local windowRead = false
local function Take(id, n, why)
  local e = expected[id]
  if not e or e.qty <= 0 or n <= 0 then return end
  if GetTime() - e.at > 5 then expected[id] = nil; return end   -- that window is long gone
  local take = math.min(n, e.qty)
  e.qty = e.qty - take
  if e.qty <= 0 then expected[id] = nil end
  D(why, e.link, "x" .. take)
  if Running() then AddItem(e.link, take, false) else D("session not running: not counted") end
end
local function ReadLootSlots()
  wipe(lootSlots)
  for id, e in pairs(expected) do if GetTime() - e.at > 5 then expected[id] = nil end end   -- leftovers
  local n = GetNumLootItems and GetNumLootItems() or 0
  for i = 1, n do
    local isItem
    if GetLootSlotType then isItem = GetLootSlotType(i) == ((Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1)
    else isItem = LootSlotHasItem and LootSlotHasItem(i) end
    if isItem then
      local link = GetLootSlotLink(i)
      local _, _, qty = GetLootSlotInfo(i)
      qty = math.max(1, tonumber(qty) or 1)
      local id = Readable(link) and tonumber(link:match("item:(%d+)"))
      D("loot slot", i, link, "x" .. qty)
      if id then
        lootSlots[i] = { id, qty }
        local e = expected[id]
        if e then e.qty, e.at = e.qty + qty, GetTime() else expected[id] = { link = link, qty = qty, at = GetTime() } end
      else
        D("slot", i, "has no readable item link")
      end
    end
  end
  D("loot window:", n, "slots")
end
local function OnLootSlotCleared(slot)
  local e = lootSlots[slot]
  D("slot taken:", slot, e and "" or "(not an item slot)")
  lootSlots[slot] = nil
  if e then Take(e[1], e[2], "counted from loot slot:") end
end

-- bags: looted items (backing up the slot signal) and quest reward items right after a turn-in
local bags
local function OnBags()
  local now = BagCounts()
  local was = bags
  bags = now
  if not was then return end
  local quest = QuestReward() and not Looting()
  for id, e in pairs(now) do
    local d = e[1] - (was[id] and was[id][1] or 0)
    if d > 0 then
      if expected[id] and Looting() then
        Take(id, d, "counted from bags:")
      elseif quest and Running() and e[2] then
        D("quest reward in bags:", e[2], "x" .. d); AddItem(e[2], d, true)
      elseif Looting() then
        D("in bags (already counted or not from the loot window):", e[2], "x" .. d)
      end
    end
  end
end

local function OnXPUpdate()
  local cur, max = UnitXP("player"), UnitXPMax("player")
  if not lastXP or not lastMax or lastMax <= 0 then lastXP, lastMax = cur, max; return end
  local d
  if cur >= lastXP then d = cur - lastXP
  else d = (lastMax - lastXP) + cur end                      -- dinged: rest of the old level + what's on the new one
  lastXP, lastMax = cur, max
  if Running() and d > 0 then S.total = S.total + d end
end

---------------------------------------------------------------- the window
local W, PAD = 280, 12
local INNER = W - PAD * 2
local SOURCES = {
  { key = "kill",    label = "Kills",        color = { 0.90, 0.36, 0.30 } },
  { key = "rested",  label = "Rested bonus", color = { 0.32, 0.58, 1.00 } },
  { key = "quest",   label = "Quests",       color = { 1.00, 0.80, 0.20 } },
  { key = "explore", label = "Exploration",  color = { 0.36, 0.84, 0.46 } },
  { key = "other",   label = "Other",        color = { 0.62, 0.62, 0.66 } },
}
local accent = { 0.56, 0.72, 1 }
local fonts, buttons, skin = {}, {}, nil

local f = CreateFrame("Frame", "XPMeterFrame", UIParent, "BackdropTemplate")
f:SetSize(W, 270); f:SetPoint("CENTER", UIParent, "CENTER", 300, 0); f:SetFrameStrata("MEDIUM"); f:Hide()
f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetClampedToScreen(true)
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, rel, x, y = self:GetPoint()
  db.pos = { point, rel, x, y }
end)

local function Text(parent, template, width, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  if width then fs:SetWidth(width) end
  fonts[#fonts + 1] = fs
  return fs
end
local function Btn(label, parent)
  local b = CreateFrame("Button", nil, parent or f, "UIPanelButtonTemplate"); b:SetHeight(22); b:SetText(label)
  buttons[#buttons + 1] = b
  return b
end

-- title row
local title = Text(f, "GameFontNormal"); title:SetPoint("TOPLEFT", PAD, -10); title:SetText("XP Meter")
local stateDot = f:CreateTexture(nil, "OVERLAY"); stateDot:SetSize(7, 7); stateDot:SetTexture("Interface/BUTTONS/WHITE8X8")
stateDot:SetPoint("LEFT", title, "RIGHT", 8, 0)
local stateText = Text(f); stateText:SetPoint("LEFT", stateDot, "RIGHT", 4, 0)
local closeX = CreateFrame("Button", nil, f, "UIPanelCloseButton"); closeX:SetSize(22, 22); closeX:SetPoint("TOPRIGHT", -3, -3)
closeX:SetScript("OnClick", function() f:Hide(); db.shown = false end)

-- Each section (XP, gold) is a headline that always shows and a body that collapses. Click a headline (or
-- its +/- box) to fold that section; the title bar's box folds both into a mini mode. Saved in db.collapsed.
local toggles = {}
local Layout   -- defined after the sections
local function Toggle(parent, key, y)
  local b = CreateFrame("Button", nil, parent); b:SetSize(INNER, 26); b:SetPoint("TOPLEFT", PAD, y)
  b.box = Btn("-", parent); b.box:SetSize(16, 16); b.box:SetPoint("LEFT", b, "LEFT", 0, 0)
  local function Flip() db.collapsed[key] = not db.collapsed[key]; Layout() end
  b:SetScript("OnClick", Flip); b.box:SetScript("OnClick", Flip)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(db.collapsed[key] and "Click to expand" or "Click to collapse")
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:RegisterForDrag("LeftButton")   -- the headline still drags the window
  b:SetScript("OnDragStart", function() f:StartMoving() end)
  b:SetScript("OnDragStop", function() f:GetScript("OnDragStop")(f) end)
  b.key = key
  toggles[#toggles + 1] = b
  return b
end

-- the XP headline: total and rate
local HEAD_X = PAD + 22   -- headline text starts right of the +/- box
local xpToggle = Toggle(f, "xp", -36)
local totalText = Text(f, "GameFontHighlightLarge"); totalText:SetPoint("TOPLEFT", HEAD_X, -38)
local rateText = Text(f, "GameFontNormal", 140, "RIGHT"); rateText:SetPoint("TOPRIGHT", -PAD, -40)
local timeText = Text(f, "GameFontDisableSmall"); timeText:SetPoint("TOPLEFT", totalText, "BOTTOMLEFT", 0, -3)
local perText = Text(f, "GameFontDisableSmall", 150, "RIGHT"); perText:SetPoint("TOPRIGHT", rateText, "BOTTOMRIGHT", 0, -5)

-- level bar, with the rested pool shaded past the fill (always shown, even with the XP section folded)
local barHolder = CreateFrame("Frame", nil, f, "BackdropTemplate"); barHolder:SetSize(INNER, 16)
barHolder:SetPoint("TOPLEFT", PAD, -84)
local barBg = barHolder:CreateTexture(nil, "BACKGROUND"); barBg:SetAllPoints(); barBg:SetColorTexture(0, 0, 0, 0.5)
local bar = CreateFrame("StatusBar", nil, barHolder); bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("BOTTOMRIGHT", -1, 1)
bar:SetStatusBarTexture("Interface/BUTTONS/WHITE8X8"); bar:SetStatusBarColor(0.58, 0.36, 0.86, 1); bar:SetMinMaxValues(0, 1)
local restedTex = bar:CreateTexture(nil, "BACKGROUND", nil, 1); restedTex:SetColorTexture(0.32, 0.58, 1, 0.35)
local barText = Text(bar, "GameFontHighlightSmall", INNER - 8, "CENTER"); barText:SetPoint("CENTER", 0, 0)
local levelText = Text(f, "GameFontDisableSmall", INNER, "LEFT"); levelText:SetPoint("TOPLEFT", barHolder, "BOTTOMLEFT", 0, -4)
local restPool = Text(f, "GameFontDisableSmall", 120, "RIGHT"); restPool:SetPoint("TOPRIGHT", barHolder, "BOTTOMRIGHT", 0, -4)

-- the XP body (the source breakdown, which folds): offsets inside it are from XP_BODY_Y
local XP_BODY_Y = -118
local xpBody = CreateFrame("Frame", nil, f); xpBody:SetPoint("TOPLEFT", 0, XP_BODY_Y); xpBody:SetWidth(W)

-- a mix inside parent: one stacked strip at y0, then a row per source; returns the strip, the rows, the y below
local function Mix(p, list, y0, valW)
  local m = CreateFrame("Frame", nil, p); m:SetSize(INNER, 5); m:SetPoint("TOPLEFT", PAD, y0)
  local bg = m:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(1, 1, 1, 0.06)
  local out = {}
  for i, src in ipairs(list) do
    local seg = m:CreateTexture(nil, "ARTWORK"); seg:SetColorTexture(src.color[1], src.color[2], src.color[3], 0.9); seg:SetHeight(5)
    local y = y0 - 12 - (i - 1) * 17
    local hit = CreateFrame("Frame", nil, p); hit:SetSize(INNER, 16); hit:SetPoint("TOPLEFT", PAD, y + 2)
    local sw = p:CreateTexture(nil, "ARTWORK"); sw:SetSize(8, 8); sw:SetPoint("TOPLEFT", PAD, y - 3)
    sw:SetColorTexture(src.color[1], src.color[2], src.color[3], 1)
    local label = Text(p); label:SetPoint("TOPLEFT", PAD + 14, y - 1)
    local pct = Text(p, "GameFontDisableSmall", 40, "RIGHT"); pct:SetPoint("TOPRIGHT", -PAD, y - 1)
    local val = Text(p, nil, valW or 90, "RIGHT"); val:SetPoint("RIGHT", pct, "LEFT", -6, 0)
    out[i] = { src = src, seg = seg, label = label, val = val, pct = pct, hit = hit }
  end
  return m, out, y0 - 12 - #list * 17
end
local mix, rows, xpBodyBottom = Mix(xpBody, SOURCES, -4)
xpBody:SetHeight(-xpBodyBottom)

-- gold: headline, then its own mix
local GOLD = {
  { key = "gCoin",   label = "Coin looted",    color = { 1.00, 0.82, 0.00 } },
  { key = "gAH",     label = "Items (AH)",     color = { 0.64, 0.42, 0.93 } },
  { key = "gVendor", label = "Items (vendor)", color = { 0.62, 0.62, 0.66 } },
  { key = "gQuest",  label = "Quest rewards",  color = { 0.36, 0.84, 0.46 } },
}
-- the gold section moves up and down with the XP body; its own body folds the same way
local goldSec = CreateFrame("Frame", nil, f); goldSec:SetWidth(W)
local goldSep = goldSec:CreateTexture(nil, "ARTWORK"); goldSep:SetColorTexture(1, 1, 1, 0.08); goldSep:SetHeight(1)
goldSep:SetPoint("TOPLEFT", PAD, 0); goldSep:SetPoint("TOPRIGHT", -PAD, 0)
local goldToggle = Toggle(goldSec, "gold", -6)
local goldText = Text(goldSec, "GameFontHighlightLarge"); goldText:SetPoint("TOPLEFT", HEAD_X, -10)
local goldRate = Text(goldSec, "GameFontNormal", 150, "RIGHT"); goldRate:SetPoint("TOPRIGHT", -PAD, -12)
local GOLD_HEAD_H = 34
local goldBody = CreateFrame("Frame", nil, goldSec); goldBody:SetPoint("TOPLEFT", 0, -GOLD_HEAD_H); goldBody:SetWidth(W)
local goldMix, goldRows, goldBodyBottom = Mix(goldBody, GOLD, -4, 130)
goldBody:SetHeight(-goldBodyBottom)

-- hovering an item row lists its most valuable items
local function ItemTip(row, which)
  row.hit:EnableMouse(true)
  row.hit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(row.src.label)
    local list = {}
    for _, e in pairs(S and S.loot or {}) do if e.src == which then list[#list + 1] = e end end
    table.sort(list, function(a, b) return a.value > b.value end)
    if #list == 0 then GameTooltip:AddLine("Nothing yet.", 0.7, 0.7, 0.7) end
    for i = 1, math.min(12, #list) do
      local e = list[i]
      GameTooltip:AddDoubleLine(e.link .. (e.count > 1 and (" x" .. e.count) or ""), Money(e.value), 1, 1, 1, 1, 1, 1)
    end
    if #list > 12 then GameTooltip:AddLine(("+ %d more"):format(#list - 12), 0.7, 0.7, 0.7) end
    if which == "ah" then GameTooltip:AddLine("Valued at Auctionator's price when looted.", 0.7, 0.7, 0.7, true) end
    if which == "vendor" then GameTooltip:AddLine("No AH price (or it was below vendor), or soulbound.", 0.7, 0.7, 0.7, true) end
    GameTooltip:Show()
  end)
  row.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
ItemTip(goldRows[2], "ah"); ItemTip(goldRows[3], "vendor"); ItemTip(goldRows[4], "quest")

-- start/stop toggle, pause/resume, reset
local startBtn, pauseBtn, resetBtn = Btn("Start"), Btn("Pause"), Btn("Reset")
local BW = math.floor((INNER - 12) / 3)
for i, b in ipairs({ startBtn, pauseBtn, resetBtn }) do
  b:SetWidth(BW); b:SetPoint("BOTTOMLEFT", PAD + (i - 1) * (BW + 6), PAD)
end
-- the title bar's box: fold both sections (mini mode) or open both
local miniBtn = Btn("-"); miniBtn:SetSize(16, 16); miniBtn:SetPoint("RIGHT", closeX, "LEFT", -4, 0)
miniBtn:SetScript("OnClick", function()
  local mini = not (db.collapsed.xp and db.collapsed.gold)
  db.collapsed.xp, db.collapsed.gold = mini, mini
  Layout()
end)
miniBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Mini mode")
  GameTooltip:AddLine("Folds both sections down to their totals. Click a section's headline to fold just that one.", 1, 1, 1, true)
  GameTooltip:Show()
end)
miniBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

function Layout()
  local c = db and db.collapsed or {}
  xpBody:SetShown(not c.xp); goldBody:SetShown(not c.gold)
  for _, t in ipairs(toggles) do t.box:SetText(c[t.key] and "+" or "-") end
  miniBtn:SetText((c.xp and c.gold) and "+" or "-")
  local y = c.xp and XP_BODY_Y or (XP_BODY_Y + xpBodyBottom)       -- bottom of the XP section
  goldSec:ClearAllPoints(); goldSec:SetPoint("TOPLEFT", 0, y - 8)
  local goldH = GOLD_HEAD_H + (c.gold and 0 or -goldBodyBottom)
  goldSec:SetHeight(goldH)
  f:SetHeight(-(y - 8 - goldH) + 10 + 22 + PAD)
end
startBtn:SetScript("OnClick", function() if S.state == "stopped" then Start() else Stop() end end)
pauseBtn:SetScript("OnClick", function() if S.state == "paused" then Resume() else Pause() end end)
resetBtn:SetScript("OnClick", function() Reset() end)
local function Tip(btn, head, body)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(head); GameTooltip:AddLine(body, 1, 1, 1, true); GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
Tip(startBtn, "Start / Stop", "Start begins a new session from zero. Stop ends it, keeps its numbers on screen and saves it to /xpm history.")
Tip(pauseBtn, "Pause / Resume", "While paused no XP, gold or time is counted.")
Tip(resetBtn, "Reset", "Zeroes the time, XP and gold. A running or paused session keeps going from zero.")
barHolder:EnableMouse(true)
barHolder:SetScript("OnEnter", function(self)
  local cur, max, rest = UnitXP("player"), UnitXPMax("player"), GetXPExhaustion() or 0
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:SetText("Level " .. UnitLevel("player"))
  GameTooltip:AddDoubleLine("XP", Commas(cur) .. " / " .. Commas(max), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("To level", Commas(max - cur), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Rested pool", Commas(rest), 0.32, 0.58, 1, 1, 1, 1)
  GameTooltip:Show()
end)
barHolder:SetScript("OnLeave", function() GameTooltip:Hide() end)

local STATE = {
  running = { "Running", 0.36, 0.84, 0.46 },
  paused  = { "Paused",  1.00, 0.80, 0.20 },
  stopped = { "Stopped", 0.62, 0.62, 0.66 },
}
local function SetEnabled(b, on) if on then b:Enable() else b:Disable() end end

function Refresh()
  if not S or not f:IsShown() then return end
  local st = STATE[S.state] or STATE.stopped
  stateText:SetText(st[1]); stateText:SetTextColor(st[2], st[3], st[4]); stateDot:SetVertexColor(st[2], st[3], st[4], 1)

  local e, rate = Elapsed(), Rate()
  totalText:SetText("+" .. Commas(S.total) .. " XP")
  rateText:SetText(rate and (Short(rate) .. " XP/hr") or "- XP/hr")
  rateText:SetTextColor(accent[1], accent[2], accent[3])
  timeText:SetText("Session " .. Clock(e))
  perText:SetText(S.kills > 0 and (Commas((S.kill + S.rested) / S.kills) .. " per kill") or "")

  local cur, max, lvl = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
  local rest = GetXPExhaustion() or 0
  if AtMaxLevel() or max <= 0 then
    bar:SetValue(1); restedTex:Hide(); barText:SetText("Level " .. lvl .. " (max)")
    levelText:SetText(""); restPool:SetText("")
  else
    local frac = cur / max
    bar:SetValue(frac)
    local w = bar:GetWidth()
    local rf = math.min(rest, max - cur) / max
    if rf > 0 and w > 0 then
      restedTex:ClearAllPoints(); restedTex:SetPoint("TOPLEFT", bar, "TOPLEFT", w * frac, 0)
      restedTex:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", w * frac, 0); restedTex:SetWidth(math.max(1, w * rf)); restedTex:Show()
    else restedTex:Hide() end
    barText:SetText(("Lvl %d   %s / %s   %.1f%%"):format(lvl, Commas(cur), Commas(max), frac * 100))
    local need = max - cur
    local eta = rate and rate > 0 and ("Level in " .. Duration(need / rate * 3600)) or "Level in -"
    local avgKill = S.kills > 0 and (S.kill + S.rested) / S.kills
    if avgKill and avgKill > 0 then eta = eta .. ("  ·  ~%s kills"):format(Commas(math.ceil(need / avgKill))) end
    levelText:SetText(eta)
    restPool:SetText(rest > 0 and ("Rested " .. Short(rest)) or "Not rested")
  end

  local function Fill(m, list, values, fmt, extra)
    local sum = 0
    for _, v in pairs(values) do sum = sum + v end
    local x, mw = 0, m:GetWidth()
    for _, r in ipairs(list) do
      local v = values[r.src.key]
      r.label:SetText(r.src.label .. (extra[r.src.key] or ""))
      r.val:SetText(fmt(v))
      r.pct:SetText(sum > 0 and ("%d%%"):format(math.floor(v / sum * 100 + 0.5)) or "-")
      local segW = sum > 0 and (v / sum * mw) or 0
      if segW >= 0.5 then
        r.seg:ClearAllPoints(); r.seg:SetPoint("TOPLEFT", m, "TOPLEFT", x, 0); r.seg:SetWidth(segW); r.seg:Show()
        x = x + segW
      else r.seg:Hide() end
    end
  end
  local function N(n) return n > 0 and (" |cFF888888(" .. n .. ")|r") or nil end
  Fill(mix, rows, { kill = S.kill, rested = S.rested, quest = S.quest, explore = S.explore, other = Other() }, Commas,
    { kill = N(S.kills), quest = N(S.quests), explore = N(S.discoveries) })

  local gold = GoldTotal(S)
  goldText:SetText("+" .. Money(gold))
  goldRate:SetText(e >= 60 and (Money(gold / e * 3600, true) .. " /hr") or "- /hr")
  goldRate:SetTextColor(accent[1], accent[2], accent[3])
  local nAH, nV, nQ = 0, 0, 0
  for _, it in pairs(S.loot) do
    if it.src == "ah" then nAH = nAH + it.count elseif it.src == "vendor" then nV = nV + it.count else nQ = nQ + it.count end
  end
  Fill(goldMix, goldRows, { gCoin = S.gCoin, gAH = S.gAH, gVendor = S.gVendor, gQuest = S.gQuest }, Money,
    { gAH = N(nAH), gVendor = N(nV), gQuest = N(nQ) })

  startBtn:SetText(S.state == "stopped" and "Start" or "Stop")
  pauseBtn:SetText(S.state == "paused" and "Resume" or "Pause")
  SetEnabled(pauseBtn, S.state ~= "stopped")
  SetEnabled(resetBtn, S.total > 0 or gold > 0 or Elapsed() > 0)
end
f:SetScript("OnShow", function() Refresh() end)

---------------------------------------------------------------- the EllesmereUI look (or a plain fallback)
local function Accent()
  if skin and skin.GetAccentColor then
    local r, g, b = skin.GetAccentColor()
    if r then accent = { r, g, b } end
  end
  Refresh()
end
local function ApplySkin(sk)
  skin = sk
  sk.Shell(f)
  sk.CloseButton(closeX)
  for _, b in ipairs(buttons) do sk.Button(b); if sk.StateButtonLabel then sk.StateButtonLabel(b) end end
  sk.Panel(barHolder, { inset = true }); barBg:SetAlpha(0)
  if sk.ApplyBarFill then sk.ApplyBarFill(bar) end
  for _, fs in ipairs(fonts) do sk.Font(fs) end
  Accent()
  if sk.OnLooksChanged then sk.OnLooksChanged(Accent) end
end
if EllesmereUI and EllesmereUI.RegisterSkin then EllesmereUI.RegisterSkin(ADDON, ApplySkin) end

local function PlainLook()   -- no EllesmereUI, or its skinning is off for XPMeter
  if skin then return end
  local flat = { bgFile = "Interface/BUTTONS/WHITE8X8", edgeFile = "Interface/BUTTONS/WHITE8X8", edgeSize = 1 }
  f:SetBackdrop(flat); f:SetBackdropColor(0.06, 0.06, 0.07, 0.94); f:SetBackdropBorderColor(0, 0, 0, 1)
  barHolder:SetBackdrop(flat); barHolder:SetBackdropColor(0, 0, 0, 0.5); barHolder:SetBackdropBorderColor(0, 0, 0, 1)
end

---------------------------------------------------------------- events
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_XP_UPDATE")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("UPDATE_EXHAUSTION")
ev:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:RegisterEvent("QUEST_TURNED_IN")
ev:RegisterEvent("CHAT_MSG_MONEY")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("LOOT_READY")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_CLOSED")
ev:RegisterEvent("LOOT_SLOT_CLEARED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:RegisterEvent("PLAYER_LOGOUT")
local reported = {}
local function OnEvent(_, event, a1, a2, a3)
  if event == "ADDON_LOADED" then
    if a1 ~= ADDON then return end
    XPMeterDB = XPMeterDB or {}
    db = XPMeterDB
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = type(v) == "table" and {} or v end end
    db.s = db.s or NewSession(); S = db.s
    for k, v in pairs(NewSession()) do if S[k] == nil then S[k] = v end end   -- sessions saved by older versions
    if S.state == "running" then activeSince = GetTime() end   -- picks up where /reload or logout left off
    if db.pos then
      f:ClearAllPoints(); f:SetPoint(db.pos[1], UIParent, db.pos[2] or db.pos[1], db.pos[3] or 0, db.pos[4] or 0)
    end
    BuildPatterns()
    Layout()
  elseif event == "PLAYER_ENTERING_WORLD" then
    lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
    lastMoney = GetMoney(); bags = BagCounts()
    if a1 or a2 then   -- login or reload
      PlainLook()
      if db.shown then f:Show() end
    end
  elseif event == "PLAYER_XP_UPDATE" or event == "PLAYER_LEVEL_UP" then
    if event == "PLAYER_XP_UPDATE" then OnXPUpdate() end
    Refresh()
  elseif event == "UPDATE_EXHAUSTION" then
    Refresh()
  elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
    OnCombatXP(a1); Refresh()
  elseif event == "CHAT_MSG_SYSTEM" then
    OnSystem(a1)
  elseif event == "QUEST_TURNED_IN" then
    OnQuest(a2, a3); Refresh()
  elseif event == "CHAT_MSG_MONEY" then
    OnMoneyChat(a1); Refresh()
  elseif event == "PLAYER_MONEY" then
    OnPlayerMoney(); Refresh()
  elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
    if not windowRead then ReadLootSlots(); windowRead = true end
    lootOpen = true
  elseif event == "LOOT_SLOT_CLEARED" then
    OnLootSlotCleared(a1); Refresh()
  elseif event == "LOOT_CLOSED" then
    lootOpen, lootClosedAt, windowRead = false, GetTime(), false   -- slots kept: Forever may report them after closing
    D("loot window closed")
  elseif event == "BAG_UPDATE_DELAYED" then
    OnBags(); Refresh()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    RetryPending()
  elseif event == "PLAYER_LOGOUT" then
    if S and S.state == "running" then S.acc = Elapsed(); activeSince = GetTime() end   -- offline time never counts
  end
end
-- an error in one event never stops the others; each kind is reported once (in chat, so hidden Lua errors show)
ev:SetScript("OnEvent", function(...)
  local ok, err = pcall(OnEvent, ...)
  if not ok then
    local event = select(2, ...)
    local key = tostring(event) .. tostring(err)
    if not reported[key] then
      reported[key] = true
      Print(("error in %s (please report it): %s"):format(tostring(event), tostring(err)))
    end
  end
end)

C_Timer.NewTicker(1, function() RetryPending(); if f:IsShown() then Refresh() end end)

---------------------------------------------------------------- slash commands
local function History()
  if #db.history == 0 then Print("no finished sessions yet."); return end
  Print("last sessions:")
  for i = 1, math.min(5, #db.history) do
    local h = db.history[i]
    local rate = h.secs >= 60 and Short(h.total / h.secs * 3600) or "-"
    DEFAULT_CHAT_FRAME:AddMessage(("  %s  %s XP in %s (%s/hr)  kills %s, rested %s, quests %s, explore %s, other %s"):format(
      h.started and date("%m/%d %H:%M", h.started) or "?", Commas(h.total), Clock(h.secs), rate,
      Short(h.kill), Short(h.rested), Short(h.quest), Short(h.explore), Short(h.other)))
    if (h.gold or 0) > 0 then
      DEFAULT_CHAT_FRAME:AddMessage(("      gold %s (%s/hr)  coin %s, items AH %s, vendor %s, quests %s"):format(Money(h.gold),
        h.secs >= 60 and Money(h.gold / h.secs * 3600, true) or "-", Money(h.gCoin, true), Money(h.gAH, true),
        Money(h.gVendor, true), Money(h.gQuest, true)))
    end
  end
end

SLASH_XPMETER1, SLASH_XPMETER2 = "/xpm", "/xpmeter"
SlashCmdList.XPMETER = function(msg)
  local cmd = strtrim((msg or ""):lower())
  if cmd == "" or cmd == "toggle" then
    if f:IsShown() then f:Hide(); db.shown = false else f:Show(); db.shown = true end
  elseif cmd == "start" then Start()
  elseif cmd == "pause" then Pause()
  elseif cmd == "resume" then Resume()
  elseif cmd == "stop" then Stop()
  elseif cmd == "reset" then Reset(); Print("session numbers cleared.")
  elseif cmd == "history" then History()
  elseif cmd == "debug" then
    db.debug = not db.debug
    Print("v" .. VERSION .. " debug " .. (db.debug and "on: loot something and the details print here." or "off.")
      .. ((db.debug and S.state ~= "running") and " The session isn't running, so nothing will be counted until you start or resume it." or ""))
  elseif cmd == "mini" then
    local mini = not (db.collapsed.xp and db.collapsed.gold)
    db.collapsed.xp, db.collapsed.gold = mini, mini
    Layout()
  else
    Print("v" .. VERSION .. "  /xpm [start | pause | resume | stop | reset | history | mini | debug]  (no argument shows or hides the window)")
  end
end
