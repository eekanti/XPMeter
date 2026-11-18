-- XPMeter: session XP tracker with start / pause / stop.
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
local VERSION = "1.0.0"

local DEFAULTS = { shown = true, history = {} }
local db                                  -- XPMeterDB (per character)
local S                                   -- this session (db.s)
local activeSince                         -- GetTime() when the current running stretch began
local lastXP, lastMax                     -- XP bar baseline for deltas

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cFF8FB8FFXPMeter|r: " .. msg) end

local function NewSession()
  return { state = "stopped", acc = 0, total = 0, kill = 0, rested = 0, quest = 0, explore = 0,
           kills = 0, quests = 0, discoveries = 0 }
end

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
  if S.total > 0 then
    table.insert(db.history, 1, { started = S.started, ended = S.ended, secs = S.acc, total = S.total, kill = S.kill,
      rested = S.rested, quest = S.quest, explore = S.explore, other = Other(), kills = S.kills, quests = S.quests })
    while #db.history > 20 do table.remove(db.history) end
  end
  Print(("session stopped: %s XP in %s (%s XP/hr)."):format(Commas(S.total), Clock(S.acc),
    S.acc >= 60 and Commas(S.total / S.acc * 3600) or "-"))
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
local function Pattern(fmt, anchorEnd)
  if type(fmt) ~= "string" then return nil end
  local p = fmt:gsub("%%%d?%$?([sd])", "\001%1")             -- placeholders (incl. %1$s) out of the way
  p = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")            -- escape the rest
  p = p:gsub("\001s", "(.-)"):gsub("\001d", "([%%d,%%.]+)")
  p = p:gsub("%%%.$", "")                                    -- trailing period optional (bonus text follows it)
  return "^" .. p .. (anchorEnd and "$" or "")
end
local function Num(s) return tonumber((tostring(s or ""):gsub("[^%d]", ""))) end

local PAT = {}
local function BuildPatterns()
  PAT.kill = Pattern(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.")
  PAT.unnamed = Pattern(COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED or "You gain %d experience.")
  PAT.explore = Pattern(ERR_ZONE_EXPLORED_XP or "Discovered %s: %d experience gained")
  PAT.restedWord = ((TUTORIAL_TITLE26 or "Rested"):lower())
end

local function OnCombatXP(text)
  if not Running() or type(text) ~= "string" then return end
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
  if not Running() or type(text) ~= "string" or not PAT.explore then return end
  local _, xp = text:match(PAT.explore)
  xp = Num(xp)
  if xp and xp > 0 then S.explore = S.explore + xp; S.discoveries = S.discoveries + 1 end
end

local function OnQuest(xpReward)
  xpReward = tonumber(xpReward)
  if not Running() or not xpReward or xpReward <= 0 or AtMaxLevel() then return end
  S.quest = S.quest + xpReward; S.quests = S.quests + 1
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
local function Btn(label)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); b:SetHeight(22); b:SetText(label)
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

-- the headline: total and rate
local totalText = Text(f, "GameFontHighlightLarge"); totalText:SetPoint("TOPLEFT", PAD, -38)
local rateText = Text(f, "GameFontNormal", 140, "RIGHT"); rateText:SetPoint("TOPRIGHT", -PAD, -40)
local timeText = Text(f, "GameFontDisableSmall"); timeText:SetPoint("TOPLEFT", totalText, "BOTTOMLEFT", 0, -3)
local perText = Text(f, "GameFontDisableSmall", 150, "RIGHT"); perText:SetPoint("TOPRIGHT", rateText, "BOTTOMRIGHT", 0, -5)

-- level bar, with the rested pool shaded past the fill
local barHolder = CreateFrame("Frame", nil, f, "BackdropTemplate"); barHolder:SetSize(INNER, 16)
barHolder:SetPoint("TOPLEFT", PAD, -84)
local barBg = barHolder:CreateTexture(nil, "BACKGROUND"); barBg:SetAllPoints(); barBg:SetColorTexture(0, 0, 0, 0.5)
local bar = CreateFrame("StatusBar", nil, barHolder); bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("BOTTOMRIGHT", -1, 1)
bar:SetStatusBarTexture("Interface/BUTTONS/WHITE8X8"); bar:SetStatusBarColor(0.58, 0.36, 0.86, 1); bar:SetMinMaxValues(0, 1)
local restedTex = bar:CreateTexture(nil, "BACKGROUND", nil, 1); restedTex:SetColorTexture(0.32, 0.58, 1, 0.35)
local barText = Text(bar, "GameFontHighlightSmall", INNER - 8, "CENTER"); barText:SetPoint("CENTER", 0, 0)
local levelText = Text(f, "GameFontDisableSmall", INNER, "LEFT"); levelText:SetPoint("TOPLEFT", barHolder, "BOTTOMLEFT", 0, -4)
local restPool = Text(f, "GameFontDisableSmall", 120, "RIGHT"); restPool:SetPoint("TOPRIGHT", barHolder, "BOTTOMRIGHT", 0, -4)

-- the mix: one stacked strip, then a row per source
local mixY = -122
local mix = CreateFrame("Frame", nil, f); mix:SetSize(INNER, 5); mix:SetPoint("TOPLEFT", PAD, mixY)
local mixBg = mix:CreateTexture(nil, "BACKGROUND"); mixBg:SetAllPoints(); mixBg:SetColorTexture(1, 1, 1, 0.06)
local rows = {}
for i, src in ipairs(SOURCES) do
  local seg = mix:CreateTexture(nil, "ARTWORK"); seg:SetColorTexture(src.color[1], src.color[2], src.color[3], 0.9); seg:SetHeight(5)
  local y = mixY - 12 - (i - 1) * 17
  local sw = f:CreateTexture(nil, "ARTWORK"); sw:SetSize(8, 8); sw:SetPoint("TOPLEFT", PAD, y - 3)
  sw:SetColorTexture(src.color[1], src.color[2], src.color[3], 1)
  local label = Text(f); label:SetPoint("TOPLEFT", PAD + 14, y - 1)
  local pct = Text(f, "GameFontDisableSmall", 40, "RIGHT"); pct:SetPoint("TOPRIGHT", -PAD, y - 1)
  local val = Text(f, nil, 90, "RIGHT"); val:SetPoint("RIGHT", pct, "LEFT", -6, 0)
  rows[i] = { src = src, seg = seg, label = label, val = val, pct = pct }
end

-- start/stop toggle, pause/resume, reset
local startBtn, pauseBtn, resetBtn = Btn("Start"), Btn("Pause"), Btn("Reset")
local BW = math.floor((INNER - 12) / 3)
for i, b in ipairs({ startBtn, pauseBtn, resetBtn }) do
  b:SetWidth(BW); b:SetPoint("BOTTOMLEFT", PAD + (i - 1) * (BW + 6), PAD)
end
f:SetHeight(-(mixY - 12 - #SOURCES * 17) + 14 + 22 + PAD)
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
Tip(pauseBtn, "Pause / Resume", "While paused no XP or time is counted.")
Tip(resetBtn, "Reset", "Zeroes the time and XP. A running or paused session keeps going from zero.")
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

  local values = { kill = S.kill, rested = S.rested, quest = S.quest, explore = S.explore, other = Other() }
  local sum = 0
  for _, v in pairs(values) do sum = sum + v end
  local x, mw = 0, mix:GetWidth()
  for _, r in ipairs(rows) do
    local v, key = values[r.src.key], r.src.key
    local label = r.src.label
    if key == "kill" and S.kills > 0 then label = label .. " |cFF888888(" .. S.kills .. ")|r" end
    if key == "quest" and S.quests > 0 then label = label .. " |cFF888888(" .. S.quests .. ")|r" end
    if key == "explore" and S.discoveries > 0 then label = label .. " |cFF888888(" .. S.discoveries .. ")|r" end
    r.label:SetText(label)
    r.val:SetText(Commas(v))
    r.pct:SetText(sum > 0 and ("%d%%"):format(math.floor(v / sum * 100 + 0.5)) or "-")
    local segW = sum > 0 and (v / sum * mw) or 0
    if segW >= 0.5 then
      r.seg:ClearAllPoints(); r.seg:SetPoint("TOPLEFT", mix, "TOPLEFT", x, 0); r.seg:SetWidth(segW); r.seg:Show()
      x = x + segW
    else r.seg:Hide() end
  end

  startBtn:SetText(S.state == "stopped" and "Start" or "Stop")
  pauseBtn:SetText(S.state == "paused" and "Resume" or "Pause")
  SetEnabled(pauseBtn, S.state ~= "stopped")
  SetEnabled(resetBtn, S.total > 0 or Elapsed() > 0)
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
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "ADDON_LOADED" then
    if a1 ~= ADDON then return end
    XPMeterDB = XPMeterDB or {}
    db = XPMeterDB
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = type(v) == "table" and {} or v end end
    db.s = db.s or NewSession(); S = db.s
    if S.state == "running" then activeSince = GetTime() end   -- picks up where /reload or logout left off
    if db.pos then
      f:ClearAllPoints(); f:SetPoint(db.pos[1], UIParent, db.pos[2] or db.pos[1], db.pos[3] or 0, db.pos[4] or 0)
    end
    BuildPatterns()
  elseif event == "PLAYER_ENTERING_WORLD" then
    lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
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
    OnQuest(a2); Refresh()
  elseif event == "PLAYER_LOGOUT" then
    if S and S.state == "running" then S.acc = Elapsed(); activeSince = GetTime() end   -- offline time never counts
  end
end)

C_Timer.NewTicker(1, function() if f:IsShown() then Refresh() end end)

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
  else
    Print("v" .. VERSION .. "  /xpm [start | pause | resume | stop | reset | history]  (no argument shows or hides the window)")
  end
end
