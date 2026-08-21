-- SimCOverride: Codec
-- Talent export strings: read the header, re-stamp the spec ID, check whether a string has any
-- talents in it, and serialize a live C_Traits config as a fallback.
--
-- Blizzard export string layout (ClassTalentImportExportMixin):
--   8 bits   serialization version
--   16 bits  spec ID
--   16 x 8   tree hash (an all-zero hash disables validation on import and is accepted)
--   then, per node in C_Traits.GetTreeNodes(treeID) order:
--     1 bit selected [ 1 bit purchased [ 1 bit partial [6 bits ranks] , 1 bit choice [2 bits idx] ] ]
--
-- Every stream body below is pcall-wrapped because MakeImportDataStream and ExtractValue both
-- raise on a malformed payload. They are file-scope functions rather than closures: the dedupe
-- pass in Registry:GetLoadouts runs them once per loadout, per menu open.

local _, ns = ...
if ns.disabled then return end

local Codec = {}
ns.Codec = Codec

local BITS_VERSION, BITS_SPEC = 8, 16
local BITS_HASH   = 128
local HEADER_BITS = BITS_VERSION + BITS_SPEC + BITS_HASH  -- 152

local EMPTY = {}

-- Pasted strings routinely arrive wrapped, indented or newline-terminated.
function Codec.Trim(str)
  return (tostring(str or ""):gsub("%s+", ""))
end

-- Trimmed, minus the "-LVL-<leveling>" tail TalentLoadoutManager appends to its export strings.
function Codec.Clean(str)
  local s = Codec.Trim(str)
  return s:match("^(.-)%-LVL%-") or s
end

local function readHeader(str)
  local stream = ExportUtil.MakeImportDataStream(str)
  if stream:GetNumberOfBits() < HEADER_BITS then return nil end
  -- Sequential: each ExtractValue advances the stream, so the order matters.
  local version = stream:ExtractValue(BITS_VERSION)
  local specID  = stream:ExtractValue(BITS_SPEC)
  return { version = version, specID = specID }
end

--- @return table|nil header  { version, specID }
--- @return string|nil err
function Codec.ReadHeader(str)
  str = Codec.Clean(str)
  if str == "" then return nil, "Nothing to read." end
  local ok, res = pcall(readHeader, str)
  if not ok then return nil, "That does not look like a talent export string." end
  if not res then return nil, "That string is too short to be a talent export." end
  return res
end

local function hasContent(str)
  local stream = ExportUtil.MakeImportDataStream(str)
  local total = stream:GetNumberOfBits()
  if total <= HEADER_BITS then return false end
  stream:ExtractValue(BITS_VERSION)
  stream:ExtractValue(BITS_SPEC)
  for _ = 1, 16 do stream:ExtractValue(8) end
  local remaining = total - HEADER_BITS
  while remaining > 0 do
    local n = math.min(remaining, 24)
    if stream:ExtractValue(n) ~= 0 then return true end
    remaining = remaining - n
  end
  return false
end

--- True if any content bit past the 152-bit header is set.
--- Deliberately tree-independent: it never touches C_Traits.GetNodeInfo, which is the one API
--- that cannot be trusted for a spec the player is not in. A config that reads back as "nothing
--- purchased" serializes to an all-zero run, and that is the failure mode we are catching.
function Codec.HasContent(str)
  local ok, res = pcall(hasContent, Codec.Clean(str))
  return ok and res or false
end

local function setHeaderSpecID(str, specID)
  local inS = ExportUtil.MakeImportDataStream(str)
  local total = inS:GetNumberOfBits()
  if total < HEADER_BITS then return nil end
  local version = inS:ExtractValue(BITS_VERSION)
  if version ~= C_Traits.GetLoadoutSerializationVersion() then return nil end
  if inS:ExtractValue(BITS_SPEC) == specID then return str end  -- already correct

  local outS = ExportUtil.MakeExportDataStream()
  outS:AddValue(BITS_VERSION, version)
  outS:AddValue(BITS_SPEC, specID)
  local remaining = total - BITS_VERSION - BITS_SPEC
  while remaining > 0 do
    local n = math.min(remaining, 16)
    outS:AddValue(n, inS:ExtractValue(n))
    remaining = remaining - n
  end
  return outS:GetExportString()
end

--- Rewrite the 16-bit header spec ID and copy the rest of the bitstream through verbatim.
--- Technique from TalentLoadoutManager core/ImportExportV2.lua:330.
--- This is what makes another spec's loadout usable at all: C_Traits.GenerateImportString and
--- SimC's own GetExportString both stamp PlayerUtil.GetCurrentSpecID() no matter which config
--- they were handed, so the header cannot be trusted until we fix it.
--- @return string|nil
function Codec.SetHeaderSpecID(str, specID)
  str = Codec.Clean(str)
  if str == "" or not specID then return nil end
  local ok, res = pcall(setHeaderSpecID, str, specID)
  return ok and res or nil
end

--- Spec-agnostic form, used only as a dedupe key when merging providers. Never emitted.
function Codec.Normalize(str)
  return Codec.SetHeaderSpecID(str, 0)
end

local function serializeConfig(configID, specID)
  local info = C_Traits.GetConfigInfo(configID)
  local treeID = info and info.treeIDs and info.treeIDs[1]
  if not treeID then return nil end

  local hash  = C_Traits.GetTreeHash(treeID)
  local nodes = C_Traits.GetTreeNodes(treeID)
  if not hash or not nodes then return nil end

  local out = ExportUtil.MakeExportDataStream()
  out:AddValue(BITS_VERSION, C_Traits.GetLoadoutSerializationVersion())
  out:AddValue(BITS_SPEC, specID)
  for _, h in ipairs(hash) do out:AddValue(8, h) end

  for _, nodeID in ipairs(nodes) do
    local n = C_Traits.GetNodeInfo(configID, nodeID)
    if not n or not n.activeRank or not n.ranksPurchased then return nil end

    local purchased = n.ranksPurchased > 0
    local selected  = purchased or (n.activeRank - n.ranksPurchased) > 0

    out:AddValue(1, selected and 1 or 0)
    if selected then
      out:AddValue(1, purchased and 1 or 0)
      if purchased then
        local partial = n.ranksPurchased ~= n.maxRanks
        out:AddValue(1, partial and 1 or 0)
        if partial then out:AddValue(6, n.ranksPurchased) end

        local choice = n.type == Enum.TraitNodeType.Selection
                    or n.type == Enum.TraitNodeType.SubTreeSelection
        out:AddValue(1, choice and 1 or 0)
        if choice then
          local active = n.activeEntry and n.activeEntry.entryID
          local idx = 0
          for i, entryID in ipairs(n.entryIDs or EMPTY) do
            if entryID == active then idx = i break end
          end
          if idx <= 0 or idx > 4 then return nil end  -- SimC raises here; we bail quietly
          out:AddValue(2, idx - 1)
        end
      end
    end
  end
  return out:GetExportString()
end

--- SimC's WriteLoadoutHeader + WriteLoadoutContent (core.lua:355-419) with two changes: it
--- takes an explicit specID instead of PlayerUtil.GetCurrentSpecID(), and it returns nil where
--- SimC calls error() on a corrupt choice node (core.lua:409), which would otherwise blow up
--- while we are quietly building a dropdown.
--- C_Traits.GetNodeInfo can return nil for another spec's config and SimC indexes it
--- unconditionally, so every field access is guarded.
--- @return string|nil
function Codec.SerializeConfig(configID, specID)
  if not configID or not specID then return nil end
  local ok, res = pcall(serializeConfig, configID, specID)
  if not ok or not res or not Codec.HasContent(res) then return nil end
  return res
end

--- Full validation for a user-pasted string.
--- @return boolean ok, number|nil specID, string|nil err
function Codec.ValidatePasted(str)
  str = Codec.Clean(str)
  if str == "" then return false, nil, "Paste a talent export string first." end

  local hdr, err = Codec.ReadHeader(str)
  if not hdr then return false, nil, err end

  local want = C_Traits.GetLoadoutSerializationVersion()
  if hdr.version ~= want then
    return false, nil,
      ("Talent string version %d, this client expects %d. Re-export it."):format(hdr.version, want)
  end

  local classID = ns.ClassIDForSpec(hdr.specID)
  if not classID then
    return false, nil, ("Spec ID %d is not recognised."):format(hdr.specID)
  end
  if classID ~= ns.classID then
    return false, nil, ("That is a %s build; you are a %s."):format(
      GetClassInfo(classID) or "another class", UnitClass("player") or "your class")
  end
  if not ns.Compat.SpecName(hdr.specID) then
    return false, nil, ("SimulationCraft has no name for spec %d."):format(hdr.specID)
  end
  if not Codec.HasContent(str) then
    return false, nil, "That build has no talents selected."
  end
  return true, hdr.specID
end
