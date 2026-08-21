-- SimcOverride: Core
-- Namespace, saved variables, class/spec lookups and event plumbing.

local _, ns = ...

local PREFIX = "|cff33ff99SimcOverride|r: "

function ns.Print(...)
  print(PREFIX .. strjoin(" ", tostringall(...)))
end

-- We hard-depend on SimulationCraft, so its OnInitialize has already run by the time we load.
-- LibStub raises rather than returning nil when AceAddon-3.0 is absent, hence the pcall.
do
  local ok, simc = pcall(function()
    return LibStub("AceAddon-3.0"):GetAddon("Simulationcraft", true)
  end)
  ns.Simc = ok and simc or nil
end

if not ns.Simc then
  ns.disabled = true
  C_Timer.After(5, function()
    ns.Print("|cffff5555could not find the SimulationCraft addon; SimcOverride is inactive.|r")
  end)
end

-- specID -> classID across every class. Static client data, but only the paste validator ever
-- asks for it, so pay for the scan on first use instead of at load.
local specToClass

function ns.ClassIDForSpec(specID)
  if not specToClass then
    specToClass = {}
    for classID = 1, (GetNumClasses and GetNumClasses() or 13) do
      local n = C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0
      for i = 1, n do
        local id = GetSpecializationInfoForClassID(classID, i)
        if id then specToClass[id] = classID end
      end
    end
  end
  return specToClass[specID]
end

-- Spec index (1..n) within the player's class, or nil if the spec isn't ours.
function ns.SpecIndexForSpec(specID)
  local n = C_SpecializationInfo.GetNumSpecializationsForClassID(ns.classID) or 0
  for i = 1, n do
    if GetSpecializationInfoForClassID(ns.classID, i) == specID then return i end
  end
end

-- Every spec of the player's class, in UI order: { {specID=, name=, icon=}, ... }
function ns.PlayerSpecs()
  local out = {}
  local n = C_SpecializationInfo.GetNumSpecializationsForClassID(ns.classID) or 0
  for i = 1, n do
    local specID, name, _, icon = GetSpecializationInfoForClassID(ns.classID, i)
    if specID then out[#out + 1] = { specID = specID, name = name, icon = icon } end
  end
  return out
end

local function CurrentSpecID()
  if PlayerUtil and PlayerUtil.GetCurrentSpecID then
    local ok, id = pcall(PlayerUtil.GetCurrentSpecID)
    if ok and id then return id end
  end
  local idx = C_SpecializationInfo.GetSpecialization()
  if idx then return (C_SpecializationInfo.GetSpecializationInfo(idx)) end
end

local function CharKey()
  local name = UnitName("player") or "?"
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if not realm or realm == "" then
    realm = select(2, UnitFullName("player")) or GetRealmName() or "?"
  end
  return name .. "-" .. realm
end

ns.DB = {}

-- Per-character record: enabled, specID, source ("tlm"|"tlex"|"blizzard"|"paste"), sourceID,
-- sourceLabel, pasteString, pasteSpecID, and cache (the Blizzard provider's cross-spec store).
local function InitDB()
  SimcOverrideDB = SimcOverrideDB or {}
  local db = SimcOverrideDB
  db.schema = db.schema or 1   -- stamped for future migrations
  db.chars = db.chars or {}

  local key = CharKey()
  local c = db.chars[key]
  if not c then c = {}; db.chars[key] = c end
  if c.enabled == nil then c.enabled = false end
  if c.specID == nil then c.specID = ns.currentSpecID end
  c.cache = c.cache or {}

  ns.DB.char = c
end

-- Trait events arrive in bursts of a dozen, so coalesce them.
local refreshPending = false

function ns.RequestRefresh(delay)
  if refreshPending then return end
  refreshPending = true
  C_Timer.After(delay or 1.0, function()
    refreshPending = false
    ns.currentSpecID = CurrentSpecID()
    local bliz = ns.Providers and ns.Providers.blizzard
    if bliz then pcall(bliz.Refresh, bliz) end
    -- The registry's dedupe memo has to be dropped after the Blizzard cache is rebuilt,
    -- and firing it is also what refreshes the UI: the panel is one of its listeners.
    if ns.Registry then ns.Registry:Fire() end
  end)
end

local loggedIn = false
local f = CreateFrame("Frame")

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

-- RegisterEvent raises on an event name the client does not know and the trait event set has
-- shifted between expansions, hence the pcalls. TRAIT_CONFIG_LIST_UPDATED is the signal that
-- the config list is actually populated; PLAYER_ENTERING_WORLD alone fires too early to trust
-- C_ClassTalents.
for _, e in ipairs({
  "TRAIT_CONFIG_LIST_UPDATED",
  "TRAIT_CONFIG_UPDATED",
  "TRAIT_CONFIG_CREATED",
  "TRAIT_CONFIG_DELETED",
  "CONFIG_COMMIT_FAILED",
  "ACTIVE_PLAYER_SPECIALIZATION_CHANGED",
}) do
  pcall(f.RegisterEvent, f, e)
end
pcall(f.RegisterUnitEvent, f, "PLAYER_SPECIALIZATION_CHANGED", "player")

f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    ns.classFile     = select(2, UnitClass("player"))
    ns.classID       = select(3, UnitClass("player"))
    ns.currentSpecID = CurrentSpecID()
    InitDB()
    loggedIn = true
    ns.RequestRefresh(2)
  elseif loggedIn then
    ns.RequestRefresh()
  end
end)
