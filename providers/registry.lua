-- SimCOverride: Provider registry
-- One interface, several backends (TalentLoadoutManager, TalentLoadoutsEx, Blizzard), merged
-- into a single deduped list per spec.
--
--- @class SimCOverrideProvider
--- @field key             string   -- "tlm" | "tlex" | "blizzard"
--- @field label           string   -- section title in the dropdown
--- @field priority        number   -- lower wins on dedupe
--- @field IsAvailable     fun(self):boolean
--- @field GetLoadouts     fun(self, specID:number):SimCOverrideLoadout[]
--- @field GetExportString fun(self, id:string|number, specID:number):string|nil, string|nil
--
--- @class SimCOverrideLoadout
--- @field id     string|number
--- @field name   string          -- already pipe-stripped
--- @field source string
--- @field specID number
--- @field usable boolean         -- false => rendered greyed with a tooltip
--- @field reason string|nil
--- @field str    string|nil       -- export string, when the provider already had to build one

local _, ns = ...
if ns.disabled then return end

local Registry = { list = {}, listeners = {} }
ns.Registry = Registry
ns.Providers = {}

-- provider id -> spec-agnostic export string, for cross-provider dedupe. Cleared whenever
-- anything signals that loadouts changed.
local normCache = {}

function Registry:Register(provider)
  ns.Providers[provider.key] = provider
  table.insert(self.list, provider)
  table.sort(self.list, function(a, b) return a.priority < b.priority end)
end

function Registry:Providers()
  local out = {}
  for _, p in ipairs(self.list) do
    local ok, avail = pcall(p.IsAvailable, p)
    if ok and avail then out[#out + 1] = p end
  end
  return out
end

-- True when a real loadout addon is present. The Blizzard provider only writes its cross-spec
-- cache when this is false: with TLM or TLEx installed, their database already is the
-- cross-spec store, and duplicating it just creates a second thing to go stale.
function Registry:HasExternalProvider()
  for _, p in ipairs(self:Providers()) do
    if p.key ~= "blizzard" then return true end
  end
  return false
end

function Registry:OnChanged(cb)
  table.insert(self.listeners, cb)
end

function Registry:Fire()
  wipe(normCache)
  for _, cb in ipairs(self.listeners) do pcall(cb) end
end

function Registry:GetExportString(source, id, specID)
  local p = ns.Providers[source]
  if not p then return nil, "That build came from an addon that is no longer loaded." end
  local ok, avail = pcall(p.IsAvailable, p)
  if not ok or not avail then
    return nil, ("%s is not loaded."):format(p.label)
  end
  local ok2, str, err = pcall(p.GetExportString, p, id, specID)
  if not ok2 then return nil, "That build could not be exported." end
  return str, err
end

local function NormalizedFor(provider, lo)
  local key = tostring(lo.source) .. ":" .. tostring(lo.id)
  local cached = normCache[key]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end
  local str = lo.str
  if not str then
    local ok, s = pcall(provider.GetExportString, provider, lo.id, lo.specID)
    str = ok and s or nil
  end
  local norm = str and ns.Codec.Normalize(str) or nil
  normCache[key] = norm or false
  return norm
end

--- Merged, deduped loadouts for a spec, sorted by provider priority then name. Callers that
--- want per-provider sections read them off the source changes in that order.
--- @param specID number
function Registry:GetLoadouts(specID)
  if not specID then return {} end
  local seenID, seenNorm, out = {}, {}, {}

  for _, p in ipairs(self:Providers()) do
    local ok, list = pcall(p.GetLoadouts, p, specID)
    if ok and list then
      for _, lo in ipairs(list) do
        -- The same Blizzard config surfaced by both TLM and our Blizzard provider is one
        -- thing. Numeric config ids cannot collide with TLM's "C_<n>" or our "X_<i>_<j>".
        local idKey = tostring(lo.id)
        if not seenID[idKey] then
          -- The same build saved into two different addons shares no id, so compare
          -- spec-agnostic export strings. Never dedupe on name: names collide freely.
          local norm = NormalizedFor(p, lo)
          if not (norm and seenNorm[norm]) then
            seenID[idKey] = true
            if norm then seenNorm[norm] = true end
            out[#out + 1] = lo
          end
        end
      end
    end
  end

  table.sort(out, function(a, b)
    if a.source ~= b.source then
      return (ns.Providers[a.source].priority or 99) < (ns.Providers[b.source].priority or 99)
    end
    return tostring(a.name):lower() < tostring(b.name):lower()
  end)
  return out
end
