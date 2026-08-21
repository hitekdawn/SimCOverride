-- SimcOverride: Hook
-- Interception of SimC's profile builder, plus the re-render path.
--
-- TalentLoadoutManager and TalentLoadoutsEx both post-hook Simulationcraft:PrintSimcProfile and
-- read-modify-write SimcEditBox, appending their own "# Saved Loadout:" blocks and recomputing
-- the checksum. We stay out of that pile-up: replacing GetSimcProfile runs strictly earlier, so
-- both of them layer cleanly on top of our already-overridden text. The catch is that our output
-- must still end in "# Checksum: <hex>" with no trailing newline, because both of them bail out
-- entirely if that anchor does not match.

local _, ns = ...
if ns.disabled then return end

local Simc = ns.Simc

--- The single decision point: what, if anything, to splice into the profile.
--- @return table|nil ov    the override to apply, or nil
--- @return string|nil err  a message worth showing in red, or nil for "just off"
function ns.BuildOverride()
  local char = ns.DB and ns.DB.char
  if not char or not char.enabled then return nil end

  local specID = char.specID
  if not specID then return nil, "Override is on but no spec is selected." end

  local specName = ns.Compat.SpecName(specID)
  if not specName then return nil, "SimulationCraft has no name for that spec." end

  local str, err
  if char.source == "paste" then
    str = char.pasteString
    if not str or str == "" then err = "Override is on but the talent string box is empty." end
  elseif char.source then
    str, err = ns.Registry:GetExportString(char.source, char.sourceID, specID)
  end
  if not str then return nil, err or "Override is on but no talent build is selected." end

  -- Applied unconditionally: a no-op when the header already matches, and it repairs both
  -- SimC's own bug (GetExportString always stamps PlayerUtil.GetCurrentSpecID()) and any stale
  -- header carried by a third-party stored string.
  str = ns.Codec.SetHeaderSpecID(str, specID)
  if not str then
    return nil, "That talent string uses an incompatible serialization version."
  end
  if not ns.Codec.HasContent(str) then
    return nil, "That build produced an empty talent string. Paste its string manually instead."
  end

  return {
    specID       = specID,
    specNameEN   = specName,
    talentString = str,
    -- Cleaned once, here: both the banner comment and the status line below assume pipe-free.
    sourceLabel  = ns.Compat.CleanLabel(char.sourceLabel or "?"),
    sourceKind   = char.source,
  }
end

--- The green status line. Shown from two places, so it lives in one.
function ns.OverrideStatus(ov)
  return ("Overriding to %s, %s (gear as equipped)."):format(ov.specNameEN, ov.sourceLabel)
end

-- Reused rather than reallocated: Rerender replays the last call's arguments.
local lastArgs, haveArgs = {}, false
local rendering = false

local origGetSimcProfile = Simc.GetSimcProfile

-- core.lua:1398 looks this up dynamically on the addon table, so replacing it covers /simc, the
-- LDB minimap button and the AddonCompartment entry alike.
function Simc:GetSimcProfile(debugOutput, noBags, showMerchant, links)
  local profile, err = origGetSimcProfile(self, debugOutput, noBags, showMerchant, links)
  lastArgs[1], lastArgs[2], lastArgs[3], lastArgs[4] = debugOutput, noBags, showMerchant, links
  haveArgs = true

  if err then return profile, err end   -- pass SimC's own errors straight through

  local ov, ovErr = ns.BuildOverride()
  if not ov then
    if ovErr then ns.UI:SetStatus(ovErr, "error") end
    return profile
  end

  local ok, newProfile, rwErr = pcall(ns.Rewrite.Apply, profile, ov)
  if not ok or not newProfile then
    ns.UI:SetStatus("Override failed: " .. tostring(ok and rwErr or newProfile), "error")
    return profile
  end

  ns.UI:SetStatus(ns.OverrideStatus(ov), "ok")
  return newProfile
end

-- SimcFrame and friends are only created on the first /simc (core.lua:904-1031), so this
-- post-hook is the reliable moment to build and attach the panel.
hooksecurefunc(Simc, "GetMainFrame", function()
  ns.UI:Ensure()
  ns.UI:Refresh()
end)

-- Replays the whole pipeline instead of re-splicing a cached original. That is the only way to
-- guarantee TLM's and TLEx's post-hooks re-apply and re-checksum on top of the new text;
-- re-splicing would silently delete their appended blocks. Costs one gear/bag rescan, which is
-- what /simc does anyway.
local pending = false

function ns:Rerender()
  if pending or not haveArgs then return end
  if not (_G.SimcFrame and _G.SimcFrame:IsShown()) then return end
  pending = true
  C_Timer.After(0, function()
    pending = false
    if rendering then return end
    if not (_G.SimcFrame and _G.SimcFrame:IsShown()) then return end
    rendering = true
    local ok, e = pcall(Simc.PrintSimcProfile, Simc, lastArgs[1], lastArgs[2], lastArgs[3], lastArgs[4])
    rendering = false
    if not ok then ns.Print("|cffff5555re-render failed:|r", tostring(e)) end
  end)
end

-- Known limitation: SimulationcraftAPI = { GetSimcProfile = Simulationcraft.GetSimcProfile }
-- (core.lua:1408) captures the function by value at load time, so any third party calling that
-- table gets the unmodified profile. We deliberately leave it alone. A caller holding that
-- reference is entitled to expect SimC's real output, and silently changing a documented API
-- out from under other addons would be worse than the gap.
