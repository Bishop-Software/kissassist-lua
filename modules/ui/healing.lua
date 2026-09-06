-- ui/healing.lua — Healing tab: Heals (thresholds) + Cures sub-tabs.

local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox

local HealingUI = {}
local _state

-- ---------------------------------------------------------------------------
-- Heal Thresholds panel
-- ---------------------------------------------------------------------------

local function splitHeal(raw)
    -- SpellName[|pct[|tag]][|condNNN]  →  spell, pct, tag, cond
    local spell, pct, tag, cond = '', '0', '', ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell = parts[1] or ''
    pct   = parts[2] or '0'
    tag   = parts[3] or ''
    return spell, pct, tag, cond
end

local function joinHeal(spell, pct, tag, cond)
    local result = spell .. '|' .. pct
    if tag  ~= '' then result = result .. '|' .. tag  end
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

function HealingUI.drawHealThresholds()
    local s = _state

    checkbox('Heals On', s.heal.healsOn ~= 0, function(v)
        s.heal.healsOn = v and 1 or 0
        Config.set('Heals', 'HealsOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local healsRaw  = Config.get('Heals', 'Heals',     nil) or {}
    local healsSize = tonumber(Config.get('Heals', 'HealsSize', '15')) or 15

    local function syncHealsArray()
        s.heal.healsArray = {}
        for _, slot in ipairs(Config.parseCondArray(healsRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.heal.healsArray[#s.heal.healsArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('heals_tbl', 5, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 2)
        ImGui.TableSetupColumn('Pct',   ImGuiTableColumnFlags.WidthFixed,    95)
        ImGui.TableSetupColumn('Tag',   ImGuiTableColumnFlags.WidthStretch,   1)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, healsSize do
            local raw     = healsRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, pct, tag, cond = splitHeal(isEmpty and '' or raw)
            local newSpell, newPct, newTag, newCond = spell, pct, tag, cond
            local sc, pc, tac, cc = false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##hspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local pctNum = tonumber(pct) or 0
            local newPctNum
            newPctNum, pc = ImGui.InputInt('##hpct' .. i, pctNum)
            if pc then newPct = tostring(math.max(1, math.min(100, newPctNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newTag, tac = ImGui.InputText('##htag' .. i, tag, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##hcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##hrem' .. i) then
                if i == healsSize and healsSize > 1 then
                    healsRaw[i] = nil
                    healsSize   = healsSize - 1
                    Config.set('Heals', 'HealsSize', tostring(healsSize))
                else
                    healsRaw[i] = 'null'
                end
                Config.set('Heals', 'Heals', healsRaw)
                Config.save()
                syncHealsArray()
            end

            if sc or pc or tac or cc then
                local spellVal = sc and newSpell or spell
                healsRaw[i] = spellVal ~= '' and joinHeal(
                    spellVal,
                    pc  and newPct or pct,
                    tac and newTag or tag,
                    cc  and newCond or cond
                ) or 'null'
                Config.set('Heals', 'Heals', healsRaw)
                Config.save()
                syncHealsArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        healsSize = healsSize + 1
        healsRaw[healsSize] = 'null'
        Config.set('Heals', 'HealsSize', tostring(healsSize))
        Config.set('Heals', 'Heals', healsRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Cures panel
-- ---------------------------------------------------------------------------

-- Parse: SpellName[|debuffType[|Me]][|condNNN]
-- debuffType absent or 'me' → no type filter; 'me' alone → self-only scope
local function splitCure(raw)
    local spell, dtype, selfOnly, cond = raw, '', false, ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell = parts[1] or ''
    local arg2 = (parts[2] or ''):lower()
    local arg3 = (parts[3] or ''):lower()
    if arg2 == 'me' then
        selfOnly = true; dtype = ''
    elseif arg2 ~= '' then
        dtype    = arg2
        selfOnly = (arg3 == 'me')
    end
    return spell, dtype, selfOnly, cond
end

local function joinCure(spell, dtype, selfOnly, cond)
    local result = spell
    if dtype ~= '' then
        result = result .. '|' .. dtype
        if selfOnly then result = result .. '|Me' end
    elseif selfOnly then
        result = result .. '|Me'
    end
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

local _CURE_TYPE_LABELS = { '(any)', 'Self', 'Disease', 'Poison', 'Curse', 'Corruption', 'Mezzed' }
local _CURE_TYPE_VALUES = { '',      'me',   'disease', 'poison', 'curse', 'corruption', 'mezzed' }

local function cureTypeToIdx(dtype, selfOnly)
    if dtype == '' and selfOnly then return 2 end  -- Self
    for i, v in ipairs(_CURE_TYPE_VALUES) do
        if v == dtype then return i end
    end
    return 1  -- (any)
end

function HealingUI.drawCures()
    local s = _state

    local curesOnLabels = { 'Off', 'Everyone', 'Self Only', 'Group Only' }
    local newCuresOnIdx, coc = ImGui.Combo('Cures Mode##curesOn', s.heal.curesOn, curesOnLabels)
    if coc then
        s.heal.curesOn = newCuresOnIdx
        Config.set('Cures', 'CuresOn', tostring(newCuresOnIdx))
        Config.save()
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local curesRaw  = Config.get('Cures', 'Cures',     nil) or {}
    local curesSize = tonumber(Config.get('Cures', 'CuresSize', '5')) or 5

    local function syncCuresArray()
        s.heal.curesArray = {}
        for _, slot in ipairs(Config.parseCondArray(curesRaw)) do
            s.heal.curesArray[#s.heal.curesArray + 1] = slot
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('cures_tbl', 5, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Type',  ImGuiTableColumnFlags.WidthFixed,   100)
        ImGui.TableSetupColumn('Self',  ImGuiTableColumnFlags.WidthFixed,    36)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, curesSize do
            local raw     = curesRaw[i] or ''
            local isEmpty = raw == '' or raw == 'null' or raw == 'NULL'
            local spell, dtype, selfOnly, cond = splitCure(isEmpty and '' or raw)

            ImGui.TableNextRow()

            -- Spell
            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local newSpell, sc = ImGui.InputText('##cspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            -- Type
            ImGui.TableNextColumn()
            local typeIdx    = cureTypeToIdx(dtype, selfOnly)
            local newTypeIdx, tc = ImGui.Combo('##ctype' .. i, typeIdx - 1, _CURE_TYPE_LABELS)
            newTypeIdx = newTypeIdx + 1  -- back to 1-based
            local newDtype    = _CURE_TYPE_VALUES[newTypeIdx] or ''
            -- 'Self' selection collapses selfOnly into the type field; clear selfOnly
            local newSelfOnly = (newTypeIdx == 2) and false or selfOnly

            -- Self checkbox — only meaningful when a debuff type (not Self) is selected
            ImGui.TableNextColumn()
            local selfEnabled = newDtype ~= '' and newDtype ~= 'me'
            if not selfEnabled then ImGui.BeginDisabled() end
            local newSelf, soc = ImGui.Checkbox('##cself' .. i, selfOnly)
            if not selfEnabled then ImGui.EndDisabled() end
            if selfEnabled and soc then newSelfOnly = newSelf end

            -- Cond
            ImGui.TableNextColumn()
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx, cc = ImGui.Combo('##ccond' .. i, condNo + 1, condLabels)
            local newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)

            if sc or tc or (selfEnabled and soc) or cc then
                local finalDtype    = tc    and newDtype    or dtype
                local finalSelf     = soc   and newSelfOnly or ((tc and newTypeIdx == 2) and false or selfOnly)
                local finalCond     = cc    and newCond     or cond
                local finalSpell    = sc    and newSpell    or spell
                local out = joinCure(finalSpell, finalDtype, finalSelf, finalCond)
                curesRaw[i] = (out == '') and 'null' or out
                Config.set('Cures', 'Cures', curesRaw)
                Config.save()
                syncCuresArray()
            end

            -- Remove
            ImGui.TableNextColumn()
            if ImGui.Button('[-]##crem' .. i) then
                if i == curesSize and curesSize > 1 then
                    curesRaw[curesSize] = nil
                    curesSize = curesSize - 1
                    Config.set('Cures', 'CuresSize', tostring(curesSize))
                else
                    curesRaw[i] = 'null'
                end
                Config.set('Cures', 'Cures', curesRaw)
                Config.save()
                syncCuresArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        curesSize = curesSize + 1
        curesRaw[curesSize] = 'null'
        Config.set('Cures', 'Cures', curesRaw)
        Config.set('Cures', 'CuresSize', tostring(curesSize))
        Config.save()
    end
end

function HealingUI.init(state)
    _state = state
end

return HealingUI
