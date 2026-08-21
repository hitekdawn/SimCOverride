-- SimCOverride: Rewrite
-- Line-oriented transformation of a finished SimC profile, plus the checksum splice.

local _, ns = ...
if ns.disabled then return end

local Rewrite = {}
ns.Rewrite = Rewrite

local SOURCE_NAMES = {
  tlm      = "Talent Loadout Manager",
  tlex     = "Talent Loadouts Ex",
  blizzard = "Blizzard loadout",
  paste    = "pasted string",
}

-- Emitted as one entry in the output list, so the embedded newlines survive the "\n" concat.
-- Substitutions, in order: old spec token, new spec token, build label, source name, spec name.
local BANNER = table.concat({
  "#",
  "# ### SimCOverride ###",
  "# spec:    %s -> %s",
  "# talents: %s (%s)",
  "# ####################",
}, "\n")

-- SimC's profile has no trailing newline: it ends on "# Checksum: xxxx". Splitting
-- (profile .. "\n") on ([^\n]*)\n therefore yields the checksum as the last element and the
-- profile's own trailing blank line as the one before it, so dropping just the checksum and
-- rejoining with "\n" reproduces the checksummed body byte for byte.
local function SplitLines(profile)
  local lines, n = {}, 0
  for line in (profile .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    lines[n] = line
  end
  return lines, n
end

--- @param profile string  exactly what Simc:GetSimcProfile returned
--- @param ov table        { specID, specNameEN, talentString, sourceLabel, sourceKind }
---        sourceLabel is expected pipe-free; ns.BuildOverride is where that happens.
--- @return string|nil newProfile
--- @return string|nil err
function Rewrite.Apply(profile, ov)
  if type(profile) ~= "string" or profile == "" then
    return nil, "empty profile"
  end
  if not ov or not ov.specID or not ov.talentString or ov.talentString == "" then
    return nil, "incomplete override"
  end
  local specName = ov.specNameEN or ns.Compat.SpecName(ov.specID)
  if not specName then
    return nil, "SimulationCraft has no name for spec " .. tostring(ov.specID)
  end

  local lines, n = SplitLines(profile)
  if not (lines[n] and lines[n]:match("^#%s*Checksum:%s*%x+$")) then
    return nil, "no checksum line found; profile left unmodified"
  end
  n = n - 1 -- drop the checksum line

  -- The banner names the spec we are replacing, and it goes in above the line that carries it.
  local wasSpec = "?"
  for i = 1, n do
    local s = lines[i]:match("^spec=(.*)$")
    if s then
      wasSpec = s
      break
    end
  end

  local specTok = ns.Compat.Tokenize(specName)
  local roleStr = ns.Compat.TranslateRole(ov.specID)
  local banner = BANNER:format(wasSpec, specTok,
    ov.sourceLabel or "?", SOURCE_NAMES[ov.sourceKind] or ov.sourceKind or "?", specName)

  local out, o = {}, 0
  local bannered = false

  for i = 1, n do
    local line = lines[i]

    if i == 1 and line:sub(1, 2) == "# " then
      -- "# <name> - <EnglishSpec> - <YYYY-MM-DD HH:MM> - <REGION>/<Realm>". None of those four
      -- fields can contain " - ", so the split is unambiguous. If it fails we leave line 1
      -- alone rather than mangling it; spec= is what actually matters.
      local a, _, c, d = line:match("^(.-) %- (.-) %- (.-) %- (.*)$")
      if a and c and d then
        line = ("%s - %s - %s - %s"):format(a, specName, c, d)
      end
    elseif line:match("^role=") then
      line = "role=" .. roleStr
    elseif line:match("^spec=") then
      line = "spec=" .. specTok
    elseif line:match("^# loot_spec=") then
      line = "# loot_spec=" .. specTok
    elseif line:match("^talents=") then
      -- Anchored, so "omnium_talents=" and the commented "# talents=" are untouched.
      line = "talents=" .. ov.talentString
    end

    -- SimC emits four "#" header comments then a blank line; slot the banner in there.
    if not bannered and line == "" then
      o = o + 1
      out[o] = banner
      bannered = true
    end

    o = o + 1
    out[o] = line
  end

  -- SimC core.lua:1383-1390 does:
  --   profile = profile .. '\n'
  --   checksum = adler32(profile:gsub("||","|"))
  --   profile = profile .. '# Checksum: ' .. ('%x'):format(checksum)
  local body = table.concat(out, "\n") .. "\n"
  local sum = ns.Compat.Adler32((body:gsub("||", "|")))
  if not sum then return nil, "profile too large to checksum" end
  return body .. "# Checksum: " .. ("%x"):format(sum)
end
