-- SimcOverride: Compat
-- Reimplementations of SimulationCraft's file-local helpers.
--
-- Tokenize, TranslateRole and adler32 are all `local function`s inside SimC's core.lua, so
-- there is no way to call them from another addon. What comes out of here has to be
-- byte-identical to what SimC would have emitted if the player really had been in the
-- overridden spec, bugs included. Don't "fix" anything in this file: a corrected value is
-- what makes our profile distinguishable from a native one.

local _, ns = ...
if ns.disabled then return end

local strbyte = string.byte

local C = {}
ns.Compat = C

-- SimC core.lua:258, minus the multibyte branch: we only ever tokenize Simc.SpecNames values,
-- which are always English, so SimC's ChrSize path is unreachable. The character class below is
-- exactly SimC's byte test (0-9, a-z, % + . _), and it drops one trailing underscore like SimC.
function C.Tokenize(str)
  local s = tostring(str or ""):lower():gsub(" ", "_")
  s = s:gsub("[^0-9a-z%%%+%._]", "")
  return (s:gsub("_$", ""))
end

-- SimC core.lua:471. Ask SimC's own RoleTable first, bugs and all:
--   * no [105] (Restoration Druid) and no [1473] (Augmentation Evoker), so both fall through
--     to the Blizzard role and come out as role=attack, since SimC maps HEALER -> attack
--   * [1480]='spell' is filed under a "-- Druid" comment, but 1480 is Devourer DH
-- Both reproduced on purpose.
function C.TranslateRole(specID)
  local r = ns.Simc and ns.Simc.RoleTable and ns.Simc.RoleTable[specID]
  if r ~= nil then return r end
  local blizz = select(5, GetSpecializationInfoByID(specID))
  if blizz == "TANK" then
    return "tank"
  elseif blizz == "DAMAGER" or blizz == "HEALER" then
    return "attack"
  end
  return ""
end

-- English spec name off SimC's own table (extras.lua:87). nil means SimC has no name for the
-- spec, and we have to refuse the override rather than tokenize a localized name into garbage.
function C.SpecName(specID)
  return ns.Simc and ns.Simc.SpecNames and ns.Simc.SpecNames[specID]
end

-- SimC core.lua:1034, verbatim. Runs over the whole profile, so string.byte is upvalued.
function C.Adler32(s)
  local prime = 65521
  local s1, s2 = 1, 0
  if #s > bit.lshift(1, 30) then return nil end
  for i = 1, #s do
    s1 = s1 + strbyte(s, i)
    s2 = s2 + s1
  end
  s1 = s1 % prime
  s2 = s2 % prime
  return bit.lshift(s2, 16) + s1
end

-- Loadout names can carry |c colour escapes, |T atlas markup and doubled ||. Strip every pipe
-- out of anything headed for a comment line: a stray pipe turns into a UI escape sequence in
-- the edit box and throws off SimC's ||->| checksum convention.
function C.CleanLabel(s)
  s = tostring(s or "")
  if C_StringUtil and C_StringUtil.StripHyperlinks then
    local ok, stripped = pcall(C_StringUtil.StripHyperlinks, s)
    if ok and stripped then s = stripped end
  end
  return (s:gsub("|+", ""):match("^%s*(.-)%s*$"))
end
