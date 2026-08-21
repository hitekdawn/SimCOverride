-- SimCOverride: Blizzard provider
--
-- The floor: C_ClassTalents configs, plus a SavedVariables cross-spec cache for users with no
-- loadout addon installed. WoW only exposes trait data for the spec you are currently in, so
-- the cache records each spec's export strings while you are sitting in it.

local _, ns = ...
if ns.disabled then return end

local P = {
  key      = "blizzard",
  label    = "Blizzard loadouts",
  priority = 30,
}

local OUT_OF_SPEC =
  "WoW only exposes talent data for the spec you are currently in. Visit this spec once, or paste an export string."

function P:IsAvailable()
  return C_ClassTalents ~= nil and C_Traits ~= nil
end

--- Three tiers, in order of trustworthiness.
function P:GetExportString(configID, specID)
  configID = tonumber(configID)
  if not configID or not specID then return nil, "Unknown loadout." end

  -- 1. Blizzard's native encoder. Works for non-active configs, but the spec ID it stamps is
  --    whatever spec the player is in, so it always needs correcting.
  local ok, s = pcall(C_Traits.GenerateImportString, configID)
  if ok and type(s) == "string" and s ~= "" then
    s = ns.Codec.SetHeaderSpecID(s, specID)
    if s and ns.Codec.HasContent(s) then return s end
  end

  -- 2. Our own serializer over the live config, with an explicit spec ID.
  local s2 = ns.Codec.SerializeConfig(configID, specID)
  if s2 then return s2 end

  -- 3. Whatever we captured while the player was last in that spec.
  local bucket = ns.DB.char and ns.DB.char.cache[specID]
  local e = bucket and bucket[configID]
  if e and e.str and ns.Codec.HasContent(e.str) then return e.str end

  return nil, "That build's talent data is not loaded while you are in another spec. Paste its string instead."
end

function P:GetLoadouts(specID)
  if not self:IsAvailable() or not specID then return {} end

  local out, live = {}, {}
  local activeID = C_ClassTalents.GetActiveConfigID()

  -- str is handed to the registry so it does not export the same live config twice. Cache
  -- entries deliberately omit it: their stored string is the last resort inside GetExportString,
  -- not necessarily what it returns today, and the dedupe key has to stay that function's answer.
  local function add(id, name, usable, reason, str)
    out[#out + 1] = {
      id = id, name = name, source = "blizzard", specID = specID,
      usable = usable, reason = reason, str = str,
    }
  end

  if specID == ns.currentSpecID and activeID then
    add(activeID, "Current talents", true)
    live[activeID] = true
  end

  local ok, list = pcall(C_ClassTalents.GetConfigIDsBySpecID, specID)
  if ok and type(list) == "table" then
    for _, configID in pairs(list) do
      if configID ~= activeID then
        local info = C_Traits.GetConfigInfo(configID)
        if info and info.type == Enum.TraitConfigType.Combat then
          live[configID] = true
          local str = self:GetExportString(configID, specID)
          add(configID, ns.Compat.CleanLabel(info.name or ("config " .. configID)),
            str ~= nil, (not str) and OUT_OF_SPEC or nil, str)
        end
      end
    end
  end

  -- Fill in from the cache for anything the live API did not surface.
  local bucket = ns.DB.char and ns.DB.char.cache[specID]
  if bucket then
    for configID, e in pairs(bucket) do
      if not live[configID] then
        add(configID, ns.Compat.CleanLabel(e.name or ("config " .. configID)) .. " (cached)",
          e.str ~= nil and ns.Codec.HasContent(e.str),
          (not e.str) and "No export string was captured for this build." or nil)
      end
    end
  end

  return out
end

--- Walk every spec of the class and record what we can reach. Skipped entirely when TLM or
--- TLEx is installed, since their database already is the cross-spec store. Existing cache
--- data is kept rather than deleted, so disabling those addons later still works.
function P:Refresh()
  if not ns.DB.char then return end
  if ns.Registry:HasExternalProvider() then return end
  if not self:IsAvailable() then return end

  local char = ns.DB.char
  local n = C_SpecializationInfo.GetNumSpecializationsForClassID(ns.classID) or 0

  for i = 1, n do
    local specID = GetSpecializationInfoForClassID(ns.classID, i)
    local ok, list = pcall(C_ClassTalents.GetConfigIDsBySpecID, specID)
    if specID and ok and type(list) == "table" and next(list) then
      local bucket = char.cache[specID] or {}
      char.cache[specID] = bucket
      local seen = {}

      for _, configID in pairs(list) do
        local info = C_Traits.GetConfigInfo(configID)
        if info and info.type == Enum.TraitConfigType.Combat then
          seen[configID] = true
          local str = self:GetExportString(configID, specID)
          if str then
            bucket[configID] = { name = info.name, str = str, updated = time() }
          elseif bucket[configID] then
            -- Never overwrite a good string captured in-spec with a bad one captured
            -- out-of-spec; just keep the name fresh.
            bucket[configID].name = info.name
          end
        end
      end

      -- Prune only for the spec we are currently in. Out-of-spec config lists can come back
      -- empty or partial and would otherwise wipe perfectly good cached entries.
      if specID == ns.currentSpecID then
        for configID in pairs(bucket) do
          if not seen[configID] then bucket[configID] = nil end
        end
      end
    end
  end
end

ns.Registry:Register(P)
