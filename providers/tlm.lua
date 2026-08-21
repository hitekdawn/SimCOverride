-- SimCOverride: TalentLoadoutManager provider
--
-- The primary source. TLM stores both mirrored Blizzard loadouts and its own custom ones (ids
-- like "C_8"), and its export path reads only its own data plus LibTalentTree. It never calls
-- C_Traits.GetNodeInfo on a live config, which is the API that cannot be trusted for a spec the
-- player is not in, so it is genuinely cross-spec safe.
--
-- TalentLoadoutManagerAPI is created in TLM's core/ManagerApi.lua, so resolve it lazily rather
-- than at file scope.

local _, ns = ...
if ns.disabled then return end

local P = {
  key      = "tlm",
  label    = "Talent Loadout Manager",
  priority = 10,
}

local function API()
  local api = _G.TalentLoadoutManagerAPI
  if api and api.GlobalAPI then return api end
end

function P:IsAvailable()
  return API() ~= nil
end

function P:GetLoadouts(specID)
  local api = API()
  if not api or not specID then return {} end

  -- On the public API specID comes FIRST (ManagerApi.lua:117). TLM's internal TLM:GetLoadouts
  -- takes classID first. Easy to get backwards.
  local ok, list = pcall(api.GlobalAPI.GetLoadouts, api.GlobalAPI, specID, ns.classID)
  if not ok or type(list) ~= "table" then return {} end

  local out = {}
  for _, li in ipairs(list) do
    if li and li.id ~= nil then
      -- li.name is the raw name; li.displayName carries icon/atlas markup we do not want.
      local name = ns.Compat.CleanLabel(li.name or li.displayName or "?")
      if li.isBlizzardLoadout and li.playerIsOwner == false and li.owner then
        name = name .. " (" .. ns.Compat.CleanLabel(li.owner) .. ")"
      end
      out[#out + 1] = {
        id     = li.id,
        name   = name,
        source = "tlm",
        specID = li.specID or specID,
        usable = true,
      }
    end
  end
  return out
end

function P:GetExportString(id, specID)
  local api = API()
  if not api then return nil, "TalentLoadoutManager is not loaded." end
  -- Second arg true = excludeLevelingString, so no "-LVL-..." suffix leaks into the profile.
  local ok, str = pcall(api.GlobalAPI.GetExportString, api.GlobalAPI, id, true)
  if not ok or type(str) ~= "string" or str == "" then
    return nil, "TalentLoadoutManager could not export that loadout."
  end
  return str
end

ns.Registry:Register(P)

-- TLM fires LoadoutListUpdated whenever its list changes; mirror that into our refresh.
-- Registry:Fire is enough on its own, the UI listens on it.
if EventUtil and EventUtil.ContinueOnAddOnLoaded then
  EventUtil.ContinueOnAddOnLoaded("TalentLoadoutManager", function()
    local api = API()
    if not api or not api.RegisterCallback or not api.Event then return end
    pcall(function()
      api:RegisterCallback(api.Event.LoadoutListUpdated, function() ns.Registry:Fire() end, ns)
    end)
  end)
end
