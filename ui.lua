-- SimcOverride: UI
-- A panel docked to the top edge of SimC's window.
--
-- The panel is a CHILD of SimcFrame, which gets us Show/Hide propagation, drag-follow and
-- resize-follow for free. It also means we never call SimcFrame:ClearAllPoints(), never touch
-- SimcScrollFrame/SimcEditBox geometry, and never read or write SimC's saved frame position.

local _, ns = ...
if ns.disabled then return end

local UI = {}
ns.UI = UI

local PANEL_HEIGHT = 78
local COLOR = {
  ok    = { 0.5, 1.0, 0.5 },
  error = { 1.0, 0.35, 0.35 },
  off   = { 0.7, 0.7, 0.7 },
}

local statusText, statusKind = nil, "off"

-- Anything that changes the selection drops the stale error, redraws and replays the export.
local function Commit()
  statusKind = "off"
  UI:Refresh()
  ns:Rerender()
end

local function SetDisabled(elem, tooltipLines)
  if not elem then return end
  if elem.SetEnabled then elem:SetEnabled(false) end
  if tooltipLines and elem.SetTooltip then
    elem:SetTooltip(function(tt)
      for i, line in ipairs(tooltipLines) do
        if i == 1 then
          GameTooltip_AddNormalLine(tt, line)
        else
          GameTooltip_AddErrorLine(tt, line)
        end
      end
    end)
  end
end

local function SpecMenu(_, root)
  local char = ns.DB.char
  for _, s in ipairs(ns.PlayerSpecs()) do
    local text = ("|T%d:16|t %s"):format(s.icon or 134400, s.name)
    local elem = root:CreateRadio(text,
      function() return char.specID == s.specID end,
      function() UI:OnSpecChosen(s.specID) end)
    if not ns.Compat.SpecName(s.specID) then
      SetDisabled(elem, { s.name, "SimulationCraft has no name for this spec yet." })
    end
  end
end

local function BuildMenu(_, root)
  local char = ns.DB.char
  if root.SetScrollMode then root:SetScrollMode(280) end

  -- One merged pass. The registry sorts by provider priority, so a change of source is exactly
  -- the section boundary. Asking each provider separately re-runs the whole merge once per
  -- provider, and the Blizzard one serializes every config it lists.
  local list = ns.Registry:GetLoadouts(char.specID)
  local section
  for _, lo in ipairs(list) do
    if lo.source ~= section then
      section = lo.source
      root:CreateTitle(ns.Providers[section].label)
    end
    local elem = root:CreateRadio(lo.name,
      function()
        return char.source == lo.source and tostring(char.sourceID) == tostring(lo.id)
      end,
      function() UI:OnBuildChosen(lo) end)
    if not lo.usable then
      SetDisabled(elem, { lo.name, lo.reason or
        "This build's talent data is not available while you are in another spec." })
    end
  end

  local any = #list > 0
  if char.pasteString and char.pasteString ~= "" and char.pasteSpecID == char.specID then
    root:CreateTitle("Pasted")
    root:CreateRadio("Pasted string",
      function() return char.source == "paste" end,
      function() UI:UsePasted() end)
    any = true
  end

  if not any then
    SetDisabled(root:CreateButton("(no saved builds for this spec)", function() end))
  end
end

local function Label(parent, text, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
  fs:SetText(text)
  return fs
end

local function Button(parent, w, h, text, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  if text then b:SetText(text) end
  b:SetScript("OnClick", onClick)
  return b
end

local function MenuButton(parent, width, generator)
  return Button(parent, width, 22, nil, function(self)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
      return ns.Print("this client does not expose MenuUtil; the dropdowns are unavailable.")
    end
    MenuUtil.CreateContextMenu(self, generator)
  end)
end

function UI:Ensure()
  if self.panel or not _G.SimcFrame or not ns.DB.char then return end
  local parent = _G.SimcFrame

  local p = CreateFrame("Frame", "SimcOverridePanel", parent, "BackdropTemplate")
  p:SetHeight(PANEL_HEIGHT)
  p:SetFrameLevel(parent:GetFrameLevel() + 10)  -- so menus render above the dialog
  p:EnableMouse(true)                           -- swallow clicks; deliberately NOT draggable
  p:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  self.panel = p

  Label(p, "SimcOverride"):SetPoint("TOPLEFT", 12, -6)

  -- Row 1: enable, spec, build
  local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", 96, -3)
  cb:SetScript("OnClick", function(self)
    ns.DB.char.enabled = self:GetChecked() and true or false
    Commit()
  end)
  self.check = cb

  local cbLabel = Label(p, "Override spec/talents", "GameFontHighlightSmall")
  cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 0)

  local specLabel = Label(p, "Spec:")
  specLabel:SetPoint("LEFT", cbLabel, "RIGHT", 14, 0)

  self.specBtn = MenuButton(p, 130, SpecMenu)
  self.specBtn:SetPoint("LEFT", specLabel, "RIGHT", 4, 0)

  local buildLabel = Label(p, "Build:")
  buildLabel:SetPoint("LEFT", self.specBtn, "RIGHT", 12, 0)

  self.buildBtn = MenuButton(p, 180, BuildMenu)
  self.buildBtn:SetPoint("LEFT", buildLabel, "RIGHT", 4, 0)

  -- Row 2: pasted talent string
  local pasteLabel = Label(p, "Talent string:")
  pasteLabel:SetPoint("TOPLEFT", 12, -32)

  local clear = Button(p, 52, 20, "Clear", function()
    local char = ns.DB.char
    UI.editBox:SetText("")
    char.pasteString, char.pasteSpecID = nil, nil
    if char.source == "paste" then
      char.source, char.sourceID, char.sourceLabel = nil, nil, nil
    end
    Commit()
  end)
  clear:SetPoint("TOPRIGHT", -10, -31)

  local use = Button(p, 44, 20, "Use", function() UI:OnPaste(UI.editBox:GetText()) end)
  use:SetPoint("RIGHT", clear, "LEFT", -4, 0)

  local eb = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
  eb:SetHeight(20)
  eb:SetPoint("LEFT", pasteLabel, "RIGHT", 10, 0)
  eb:SetPoint("RIGHT", use, "LEFT", -8, 0)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(0)
  -- Commit only on Enter / Use / focus loss. Committing re-renders, and SimcEditBox has
  -- SetAutoFocus(true) plus a HighlightText() at the end of every render, so committing per
  -- keystroke would rip focus away mid-typing.
  eb:SetScript("OnEnterPressed", function(self) self:ClearFocus(); UI:OnPaste(self:GetText()) end)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); UI:Refresh() end)
  eb:SetScript("OnEditFocusLost", function(self)
    local t = ns.Codec.Trim(self:GetText())
    if t ~= "" and t ~= ns.Codec.Clean(ns.DB.char.pasteString or "") then UI:OnPaste(t) end
  end)
  self.editBox = eb

  -- Row 3: status line
  local st = Label(p, "", "GameFontHighlightSmall")
  st:SetPoint("TOPLEFT", 12, -56)
  st:SetPoint("TOPRIGHT", -12, -56)
  st:SetJustifyH("LEFT")
  st:SetWordWrap(false)
  self.status = st

  self:Anchor()
  parent:HookScript("OnShow", function() UI:Anchor(); UI:Refresh() end)

  self:Refresh()
end

-- SimcFrame is SetClampedToScreen(true), which clamps the parent but not us. If the window is
-- parked at the very top of the screen, dock below it instead of above.
function UI:Anchor()
  local p, parent = self.panel, _G.SimcFrame
  if not p or not parent then return end
  p:ClearAllPoints()
  local top = parent:GetTop()
  if top and (top + PANEL_HEIGHT + 4) > UIParent:GetTop() then
    p:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", 0, -2)
    p:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", 0, -2)
  else
    p:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", 0, 2)
    p:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", 0, 2)
  end
end

function UI:SetStatus(msg, kind)
  statusText, statusKind = msg, kind or "off"
  if not self.status then return end
  self.status:SetText(msg or "")
  local c = COLOR[statusKind] or COLOR.off
  self.status:SetTextColor(c[1], c[2], c[3])
end

function UI:Refresh()
  local char = ns.DB and ns.DB.char
  if not char or not self.panel then return end

  self.check:SetChecked(char.enabled)
  self.specBtn:SetText(ns.Compat.SpecName(char.specID) or "Pick a spec")
  self.buildBtn:SetText(char.source == "paste" and "Pasted string"
    or char.sourceLabel or "Pick a build")

  if not self.editBox:HasFocus() then
    self.editBox:SetText(char.pasteString or "")
    self.editBox:SetCursorPosition(0)
  end

  if not char.enabled then
    self:SetStatus("Override off. The profile is your live spec and talents.", "off")
  elseif statusKind == "error" and statusText then
    self:SetStatus(statusText, "error")
  else
    local ov, err = ns.BuildOverride()
    if ov then
      self:SetStatus(ns.OverrideStatus(ov), "ok")
    else
      self:SetStatus(err or "Pick a spec and a build.", "error")
    end
  end
end

function UI:OnSpecChosen(specID)
  local char = ns.DB.char
  if char.specID == specID then return end
  char.specID = specID
  -- The old selection belongs to a different spec, so drop it.
  char.source, char.sourceID, char.sourceLabel = nil, nil, nil

  -- With exactly one usable build for the new spec there is nothing to choose, so take it.
  local n, only = 0, nil
  for _, lo in ipairs(ns.Registry:GetLoadouts(specID)) do
    if lo.usable then n, only = n + 1, lo end
  end
  if n == 1 then
    char.source, char.sourceID, char.sourceLabel = only.source, only.id, only.name
  elseif char.pasteString and char.pasteSpecID == specID then
    char.source, char.sourceLabel = "paste", "pasted string"
  end

  Commit()
end

function UI:OnBuildChosen(lo)
  local char = ns.DB.char
  local str, err = ns.Registry:GetExportString(lo.source, lo.id, char.specID)
  if not str then
    statusKind = "error"
    return self:SetStatus(err or "Could not export that build.", "error")
  end
  char.source, char.sourceID, char.sourceLabel = lo.source, lo.id, lo.name
  Commit()
end

function UI:UsePasted()
  local char = ns.DB.char
  if not char.pasteString then return end
  char.source, char.sourceID, char.sourceLabel = "paste", nil, "pasted string"
  Commit()
end

function UI:OnPaste(raw)
  local str = ns.Codec.Clean(raw)
  if str == "" then
    -- Nothing stored changed, so nothing to re-render.
    statusKind = "off"
    return self:Refresh()
  end

  local ok, specID, err = ns.Codec.ValidatePasted(str)
  if not ok then
    statusKind = "error"
    return self:SetStatus(err, "error")
  end

  local char = ns.DB.char
  char.pasteString = str
  char.pasteSpecID = specID
  char.specID      = specID      -- spec, loot_spec and role all follow from this
  char.source      = "paste"
  char.sourceID    = nil
  char.sourceLabel = "pasted string"
  char.enabled     = true

  Commit()
end

ns.Registry:OnChanged(function() if UI.panel then UI:Refresh() end end)
