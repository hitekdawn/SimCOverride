-- SimcOverride: TalentLoadoutsEx provider
--
-- TLEx has no usable API: _G.TLX.GetLoadedData() only returns the currently-active loadout and
-- needs the talents UI to have been opened first. So we read its account-wide SavedVariable
-- global directly. Unsupported, but the table is a plain, stable shape and its `.text` fields
-- are already finished Blizzard export strings, baked at save time while the player was in that
-- spec, which makes them cross-spec safe with no live config involved.
--
-- Shape: TalentLoadoutEx[ENGLISH_CLASS][specIndex] = ordered array of entries.
--   * an entry with no `.text` is a GROUP HEADER, not a loadout
--   * an entry with `.isLegacy` is pre-Dragonflight and cannot be exported

local _, ns = ...
if ns.disabled then return end

local P = {
  key      = "tlex",
  label    = "Talent Loadouts Ex",
  priority = 20,
}

local function SpecTable(specID)
  local idx = ns.SpecIndexForSpec(specID)
  local classTbl = idx and _G.TalentLoadoutEx and _G.TalentLoadoutEx[ns.classFile]
  local specTbl = classTbl and classTbl[idx]
  if type(specTbl) ~= "table" then return nil end
  return specTbl, idx
end

function P:IsAvailable()
  return C_AddOns.IsAddOnLoaded("TalentLoadoutsEx") and type(_G.TalentLoadoutEx) == "table"
end

function P:GetLoadouts(specID)
  if not self:IsAvailable() or not specID then return {} end
  local specTbl, idx = SpecTable(specID)
  if not specTbl then return {} end

  local out = {}
  for i, d in ipairs(specTbl) do
    if type(d) == "table" and type(d.text) == "string" and d.text ~= "" and not d.isLegacy then
      -- The spec is implicit in the table position and also embedded in the string header. If
      -- the two disagree the entry was mis-filed, so skip it rather than offering a build that
      -- claims a spec it is not.
      local hdr = ns.Codec.ReadHeader(d.text)
      if hdr and hdr.specID == specID then
        out[#out + 1] = {
          id     = ("X_%d_%d"):format(idx, i),
          name   = ns.Compat.CleanLabel(d.name or ("#" .. i)),
          source = "tlex",
          specID = specID,
          usable = true,
        }
      end
    end
  end
  return out
end

function P:GetExportString(id, specID)
  if not self:IsAvailable() then return nil, "TalentLoadoutsEx is not loaded." end
  local idx, i = tostring(id):match("^X_(%d+)_(%d+)$")
  if not idx then return nil, "Malformed TalentLoadoutsEx id." end

  local classTbl = _G.TalentLoadoutEx[ns.classFile]
  local specTbl = classTbl and classTbl[tonumber(idx)]
  local d = specTbl and specTbl[tonumber(i)]
  if not d or type(d.text) ~= "string" then
    return nil, "That TalentLoadoutsEx entry no longer exists."
  end

  -- TLEx stores whatever was exported at save time; force the header to the requested spec.
  local str = ns.Codec.SetHeaderSpecID(d.text, specID)
  if not str then
    return nil, "That TalentLoadoutsEx entry uses an incompatible serialization version."
  end
  return str
end

ns.Registry:Register(P)

-- No change callbacks to hook, but the dropdown's menu generator runs on every open, so the
-- list stays current for free.
