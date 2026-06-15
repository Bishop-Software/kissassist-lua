-- Macro Condition Builder v0.4 - aquietone (MIT)
-- Original: https://github.com/aquietone/condition-builder
-- Adapted for KissAssist: converted from standalone script to embedded module.
-- Exposes CondBuilder.open(slot, text, onAccept) and CondBuilder.draw().

local mq    = require('mq')
local ImGui = require('ImGui')

local CondBuilder = {}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local _isOpen       = false
local _slot         = nil   -- condition slot index being edited
local _onAccept     = nil   -- callback(slot, newValue) fired on Apply
local _expression   = ''
local _filteredOpts = { filterType = 1 }

-- TLO list built lazily on first draw so MQ2 is fully initialised
local TLOOptions = nil

-- ---------------------------------------------------------------------------
-- TLO list: try runtime enumeration, fall back to hardcoded
-- ---------------------------------------------------------------------------

-- mq.TLO is userdata so pairs() cannot enumerate it; use a curated list.
local function buildTLOOptions()
    return {
        'Me', 'Target', 'Spawn', 'SpawnCount', 'Spell', 'Math',
        'Cursor', 'Defined', 'FindItem', 'FindItemCount', 'Group', 'Raid',
        'If', 'Select', 'Range', 'String', 'Int', 'Bool',
        'BurnAllNamed',
    }
end

-- ---------------------------------------------------------------------------
-- Operator buttons and example expressions
-- ---------------------------------------------------------------------------

local buttons = {
    '${', '}', '[', ']', '(', ')', '.', '!', '&&', '||', '==', '!=', 'Equal', 'NotEqual', 'NULL'
}

local examples = {
    '${Target.Named}',
    '${Me.PctHPs} > 70 && ${Me.PctMana} < 60',
    '${SpawnCount[pc radius 60]} > 3',
    '${Target.CleanName.Equal[Fippy Darkpaw]}',
    '${Select[${Target.Class.ShortName},CLR,DRU,SHM]}',
    '(${Me.XTarget} > 2 || ${Target.Named}) && ${BurnAllNamed}',
    '!${Me.Buff[Illusion Benefit Greater Jann].ID}',
    '${SpawnCount[${Me.Name}`s pet]} > 0',
    '${Me.XTarget} > 0',
}

-- ---------------------------------------------------------------------------
-- Autocomplete: pattern matching → TLO member lookups via MQ2 data API
-- ---------------------------------------------------------------------------

local typePatterns = {
    { -- ${Me
        groups = '.*%${(%w*)$',
        prefix  = '(.*%${)%w*$',
    },
    { -- ${Me.PctHPs
        groups = '.*%${(%w*)%.(%w*)$',
        prefix  = '(.*%${%w*%.)%w*$',
        dataTypeName = function(tloName, memberInput)
            if not tloName then return nil, nil end
            return mq.gettype(mq.TLO[tloName]), memberInput
        end,
    },
    { -- ${FindItem[water flask].NoDrop
        groups = '.*%${(%w*)%[([%w%d%s=]*)%]%.(%w*)$',
        prefix  = '(.*%${%w*%[[%w%d%s=]*%]%.)%w*$',
        dataTypeName = function(tloName, param, memberInput)
            if not (tloName and param) then return nil, nil end
            return mq.gettype(mq.TLO[tloName](param)), memberInput
        end,
    },
    { -- ${Me.TargetOfTarget.Name
        groups = '.*%${(%w*)%.(%w*)%.(%w*)$',
        prefix  = '(.*%${%w*%.%w*%.)%w*$',
        dataTypeName = function(tloName, firstMember, memberInput)
            if not (tloName and firstMember) then return nil, nil end
            return mq.gettype(mq.TLO[tloName][firstMember]), memberInput
        end,
    },
    { -- ${Me.Inventory[chest].Name
        groups = '.*%${(%w*)%.(%w*)%[([%w%d%s=]*)%]%.(%w*)$',
        prefix  = '(.*%${%w*%.%w*%[[%w%d%s=]*%]%.)%w*$',
        dataTypeName = function(tloName, firstMember, param, memberInput)
            if not (tloName and firstMember and param) then return nil, nil end
            return mq.gettype(mq.TLO[tloName][firstMember](param)), memberInput
        end,
    },
    { -- ${Me.Buff[spirit of wolf].Duration.TimeHMS
        groups = '.*%${(%w*)%.(%w*)%[([%w%d%s=]*)%]%.(%w*)%.(%w*)$',
        prefix  = '(.*%${%w*%.%w*%[[%w%d%s=]*%]%.%w*%.)%w*$',
        dataTypeName = function(tloName, firstMember, param, secondMember, memberInput)
            if not (tloName and firstMember and param and secondMember) then return nil, nil end
            return mq.gettype(mq.TLO[tloName][firstMember](param)[secondMember]), memberInput
        end,
    },
    { -- ${Me.Inventory[23].Item[1].Name
        groups = '.*%${(%w*)%.(%w*)%[([%w%d%s=]*)%]%.(%w*)%[([%w%d%s=]*)%]%.(%w*)$',
        prefix  = '.*%${%w*%.%w*%[[%w%d%s=]*%]%.%w*%[[%w%d%s=]*%]%.)%w*$',
        dataTypeName = function(tloName, firstMember, param, secondMember, secondParam, memberInput)
            if not (tloName and firstMember and param and secondMember and secondParam) then return nil, nil end
            return mq.gettype(mq.TLO[tloName][firstMember](param)[secondMember](secondParam)), memberInput
        end,
    },
}

local function getMembersForDataType(dataTypeName, input, filterType)
    local options = {}
    local dataType = mq.TLO.Type(dataTypeName) ---@diagnostic disable-line: param-type-mismatch
    for i = 0, 300 do
        local member = dataType.Member(i)()
        if member and member:find(input) then
            table.insert(options, member)
            options[member] = true
        end
    end
    if dataType.InheritedType() then
        local parent = mq.TLO.Type(dataType.InheritedType) ---@diagnostic disable-line: param-type-mismatch
        for i = 0, 300 do
            local member = parent.Member(i)()
            if member and not options[member] and member:find(input) then
                table.insert(options, member)
            end
        end
    end
    options.filterType = filterType
    table.sort(options)
    return options
end

local function getFilteredOptions(expression)
    local options = {}
    local tloInput = expression:match(typePatterns[1].groups)
    if tloInput then
        for _, tlo in ipairs(TLOOptions) do ---@diagnostic disable-line: param-type-mismatch
            if tlo:find(tloInput) then
                table.insert(options, tlo)
            end
        end
        options.filterType = 1
        return options
    end
    for i = 2, 7 do
        local tp = typePatterns[i]
        local dataTypeName, memberInput = tp.dataTypeName(expression:match(tp.groups))
        if dataTypeName then
            return getMembersForDataType(dataTypeName, memberInput, i)
        end
    end
    return options
end

-- ---------------------------------------------------------------------------
-- ImGui sub-widgets
-- ---------------------------------------------------------------------------

local COMBO_POPUP_FLAGS = bit32.bor(
    ImGuiWindowFlags.NoTitleBar,
    ImGuiWindowFlags.NoMove,
    ImGuiWindowFlags.NoResize
)

local function ComboFiltered(label, current_value, options)
    local avail = ImGui.GetContentRegionAvailVec()
    ImGui.SetNextItemWidth(avail.x - ImGui.CalcTextSize(label))
    local result, changed = ImGui.InputText(label, current_value, ImGuiInputTextFlags.EnterReturnsTrue)
    local active = ImGui.IsItemActive()
    -- Open popup whenever the input is focused and options exist.
    -- Called every frame so the popup appears as soon as a pattern matches.
    if active and #options > 0 then ImGui.OpenPopup('##combopopup' .. label) end
    local itemMinX, _  = ImGui.GetItemRectMin()
    local _, itemMaxY  = ImGui.GetItemRectMax()
    ImGui.SetNextWindowPos(itemMinX, itemMaxY)
    ImGui.SetNextWindowSize(
        avail.x - ImGui.CalcTextSize(label),
        #options > 20 and ImGui.GetTextLineHeight() * 20 or -1
    )
    if ImGui.BeginPopup('##combopopup' .. label, COMBO_POPUP_FLAGS) then
        for _, value in ipairs(options) do
            if ImGui.Selectable(value) then
                local prefix = current_value:match(typePatterns[options.filterType].prefix)
                result = prefix .. value
            end
        end
        -- Close on Enter, focus lost, or no options left (pattern no longer matches)
        if changed or #options == 0 or (not active and not ImGui.IsWindowFocused()) then
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    end
    return result, current_value ~= result
end

local function drawReferenceLink()
    if ImGui.Button('\xee\x89\x90 TLO Reference') then
        os.execute('start https://docs.macroquest.org/reference/top-level-objects/')
    end
end

local function drawButtons(expression)
    local result = expression
    ImGui.Separator()
    for i, button in ipairs(buttons) do
        if ImGui.Button(button) then
            result = expression .. button
        end
        if i % 9 ~= 0 then ImGui.SameLine() end
    end
    return result
end

local function drawExamples(expression)
    local result = expression
    ImGui.Separator()
    if ImGui.BeginCombo('Examples', '') then
        for _, example in ipairs(examples) do
            if ImGui.Selectable(example) then
                result = example
            end
        end
        ImGui.EndCombo()
    end
    return result
end

local function drawOutput(expression)
    ImGui.Separator()
    ImGui.Text('Output')
    if ImGui.BeginChild('outputchild', -1, ImGui.GetTextLineHeightWithSpacing() * 3, ImGuiChildFlags.Borders, 0) then
        ImGui.TextWrapped(mq.parse(expression))
    end
    ImGui.EndChild()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open the condition builder window pre-filled with `currentText`.
--- `onAccept(slot, newValue)` is called when the user clicks Apply.
function CondBuilder.open(slot, currentText, onAccept)
    _slot         = slot
    _expression   = currentText or ''
    _onAccept     = onAccept
    _filteredOpts = { filterType = 1 }
    _isOpen       = true
end

--- Call from the kissassist ImGui frame callback every frame.
function CondBuilder.draw()
    if not _isOpen then return end

    -- Lazy-build TLO list once after MQ2 is fully up
    if not TLOOptions then TLOOptions = buildTLOOptions() end

    local title = _slot and string.format('Condition Builder – Cond %03d', _slot) or 'Condition Builder'
    local open, isDraw = ImGui.Begin(title, _isOpen)
    _isOpen = open

    if isDraw then
        drawReferenceLink()

        local result, changed = ComboFiltered('Condition', _expression, _filteredOpts)
        if changed then
            _expression   = result
            _filteredOpts = getFilteredOptions(_expression)
        end

        _expression = drawButtons(_expression)
        _expression = drawExamples(_expression)
        drawOutput(_expression)

        ImGui.Separator()
        if ImGui.Button('Apply') then
            if _onAccept then _onAccept(_slot, _expression) end
            _isOpen = false
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel') then
            _isOpen = false
        end
    end

    ImGui.End()
end

return CondBuilder
