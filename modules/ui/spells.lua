-- ui/spells.lua — Spells tab: Spell Slots, Buffs, GoM sub-tabs.

local mq = require('mq')
local Helpers  = require('modules.ui.helpers')
local Config   = Helpers.Config
local checkbox = Helpers.checkbox
local intInput = Helpers.intInput

local SpellsUI = {}
local _state

-- ---------------------------------------------------------------------------
-- Spell Slots panel
-- ---------------------------------------------------------------------------

local LSS_LABELS = { 'Off', 'Named Set', 'From INI' }

function SpellsUI.drawSpellSlots()
    checkbox('Check Stuck Gem', _state.cast.checkStuckGem, function(v)
        _state.cast.checkStuckGem = v
        Config.set('Spells', 'CheckStuckGem', v and '1' or '0')
        Config.save()
    end)
    checkbox('Casting Interrupt', (_state.cast.castingInterruptOn or 0) ~= 0, function(v)
        local val = v and 62 or 0
        _state.cast.castingInterruptOn = val
        Config.set('Spells', 'CastingInterruptOn', tostring(val))
        Config.save()
    end)

    ImGui.Spacing()

    -- Load Spell Set mode combo
    local lssMode = _state.cast.loadSpellSet or 0
    ImGui.PushItemWidth(120)
    local newModeIdx, modeChanged = ImGui.Combo('Load Spell Set##lss', lssMode + 1, LSS_LABELS)
    ImGui.PopItemWidth()
    if modeChanged then
        lssMode = newModeIdx - 1
        _state.cast.loadSpellSet = lssMode
        Config.set('Spells', 'LoadSpellSet', tostring(lssMode))
        Config.save()
    end

    -- SpellSetName input (only visible in mode 1)
    if lssMode == 1 then
        local setName = _state.cast.spellSetName or ''
        ImGui.PushItemWidth(180)
        local newName, nameChanged = ImGui.InputText('Set Name##lssname', setName, 0)
        ImGui.PopItemWidth()
        if nameChanged and newName ~= setName then
            _state.cast.spellSetName = newName
            Config.set('Spells', 'SpellSetName', newName)
            Config.save()
        end
    end

    ImGui.Spacing()
    local gemSlots = _state.cast.gemSlots or 8
    local gems = Config.get('Spells', 'Gems', {})
    ImGui.PushItemWidth(300)
    for i = 1, gemSlots do
        local current = gems[i] or ''
        local newVal, changed = ImGui.InputText('Gem ' .. i .. '##gem' .. i, current, 0)
        if changed and newVal ~= current then
            gems[i] = newVal
            Config.set('Spells', 'Gems', gems)
            Config.save()
        end
    end
    ImGui.PopItemWidth()

    ImGui.Spacing()
    if ImGui.Button('Write Current Gems') then
        Config.writeSpells(_state)
    end
    ImGui.SameLine()
    if lssMode == 0 then ImGui.BeginDisabled() end
    if ImGui.Button('Mem Spells') then
        _state.cast.pendingLoadSpellSet = true
    end
    if lssMode == 0 then ImGui.EndDisabled() end
end

-- ---------------------------------------------------------------------------
-- Buffs panel
-- ---------------------------------------------------------------------------

local function splitBuff(raw)
    -- SpellName[|TargetTag][|condNNN]  →  spell, tag, cond
    local spell, tag, cond = raw, '', ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond  = raw:sub(condPos + 1)
        spell = raw:sub(1, condPos - 1)
    end
    local pipePos = spell:find('|')
    if pipePos then
        tag   = spell:sub(pipePos + 1)
        spell = spell:sub(1, pipePos - 1)
    end
    return spell, tag, cond
end

local function joinBuff(spell, tag, cond)
    local result = spell
    if tag  ~= '' then result = result .. '|' .. tag  end
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

function SpellsUI.drawBuffs()
    local s = _state

    checkbox('Buffs On', s.buffs.buffsOn, function(v)
        s.buffs.buffsOn = v
        Config.set('Buffs', 'BuffsOn', v and '1' or '0')
        Config.save()
    end)
    checkbox('Rebuff On', s.buffs.rebuffOn, function(v)
        s.buffs.rebuffOn = v
        Config.set('Buffs', 'RebuffOn', v and '1' or '0')
        Config.save()
    end)
    checkbox('Mount On', s.misc.mountOn, function(v)
        s.misc.mountOn = v
        Config.set('General', 'MountOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('Check Timer', s.buffs.checkBuffsTimer, 1, 3600, 'Buffs', 'CheckBuffsTimer',
        function(v) s.buffs.checkBuffsTimer = v end)

    -- Misc Gem Re-Mem (mac:4701-4705)
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text('Misc Gem Re-Mem')
    ImGui.Spacing()
    local REMEM_LABELS = { 'Off', 'Both', 'Short only', 'LW only' }
    ImGui.PushItemWidth(130)
    local newRemem, rrc = ImGui.Combo('Re-Mem Mode##miscremem', _state.cast.miscGemRemem, REMEM_LABELS)
    ImGui.PopItemWidth()
    if rrc then
        _state.cast.miscGemRemem = newRemem
        Config.set('Spells', 'MiscGemRemem', tostring(newRemem))
        Config.save()
    end
    if (_state.cast.miscGemRemem or 0) ~= 0 then
        local maxGem = _state.cast.gemSlots or 8
        intInput('Misc Gem##miscgem', _state.cast.miscGem, 0, maxGem, 'Spells', 'MiscGem',
            function(v)
                _state.cast.miscGem = v
                _state.cast.reMemMiscSpell = v > 0 and (mq.TLO.Me.Gem(v).Name() or '') or ''
            end)
        intInput('Misc Gem LW##miscgemlw', _state.cast.miscGemLW, 0, maxGem, 'Spells', 'MiscGemLW',
            function(v)
                _state.cast.miscGemLW = v
                _state.cast.reMemMiscSpellLW = v > 0 and (mq.TLO.Me.Gem(v).Name() or '') or ''
            end)
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local buffsRaw  = Config.get('Buffs', 'Buffs',     nil) or {}
    local buffsSize = tonumber(Config.get('Buffs', 'BuffsSize', '20')) or 20

    local function syncBuffsArray()
        s.buffs.buffsArray = {}
        for _, slot in ipairs(Config.parseCondArray(buffsRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.buffs.buffsArray[#s.buffs.buffsArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('buffs_tbl', 4, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 2)
        ImGui.TableSetupColumn('Tag',   ImGuiTableColumnFlags.WidthStretch,   1)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, buffsSize do
            local raw     = buffsRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, tag, cond = splitBuff(isEmpty and '' or raw)
            local sc, tc, cc = false, false, false
            local newSpell, newTag, newCond = spell, tag, cond

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##bspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newTag, tc = ImGui.InputText('##btag' .. i, tag, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##buffrem' .. i) then
                if i == buffsSize and buffsSize > 1 then
                    buffsRaw[i] = nil
                    buffsSize   = buffsSize - 1
                    Config.set('Buffs', 'BuffsSize', tostring(buffsSize))
                else
                    buffsRaw[i] = 'null'
                end
                Config.set('Buffs', 'Buffs', buffsRaw)
                Config.save()
                syncBuffsArray()
            end

            if sc or tc or cc then
                local spellVal = sc and newSpell or spell
                buffsRaw[i] = spellVal ~= '' and joinBuff(
                    spellVal,
                    tc and newTag  or tag,
                    cc and newCond or cond
                ) or 'null'
                Config.set('Buffs', 'Buffs', buffsRaw)
                Config.save()
                syncBuffsArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        buffsSize = buffsSize + 1
        buffsRaw[buffsSize] = 'null'
        Config.set('Buffs', 'BuffsSize', tostring(buffsSize))
        Config.set('Buffs', 'Buffs', buffsRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- GoM (Gift of Mana) spell list panel
-- ---------------------------------------------------------------------------

local GOM_TARGETS = { 'MA', 'Me', 'Mob' }

local function splitGom(raw)
    -- "SpellName|Target" → spell, target
    if not raw or raw == 'null' or raw == '' then return '', 'MA' end
    local spell, tgt = raw:match('^([^|]+)|(.+)$')
    if spell then return spell, tgt end
    return raw, 'MA'
end

local function joinGom(spell, tgt)
    return spell .. '|' .. tgt
end

function SpellsUI.drawGoM()
    local gomRaw  = Config.get('GoM', 'GoMSpell', nil) or {}
    local gomSize = tonumber(Config.get('GoM', 'GoMSize', '3')) or 3

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('gom_tbl', 3, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,   70)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, gomSize do
            local raw          = gomRaw[i] or 'null'
            local spell, tgt   = splitGom(raw)
            local sc, tc       = false, false
            local newSpell, newTgt = spell, tgt

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##gomspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local tgtIdx = 0
            for j, v in ipairs(GOM_TARGETS) do
                if v == tgt then tgtIdx = j - 1 break end
            end
            local newTgtIdx
            newTgtIdx, tc = ImGui.Combo('##gomtgt' .. i, tgtIdx, GOM_TARGETS)
            newTgt = GOM_TARGETS[newTgtIdx + 1] or 'MA'
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##gomrem' .. i) then
                if i == gomSize and gomSize > 1 then
                    gomRaw[i] = nil
                    gomSize   = gomSize - 1
                    Config.set('GoM', 'GoMSize', tostring(gomSize))
                else
                    gomRaw[i] = 'null'
                end
                Config.set('GoM', 'GoMSpell', gomRaw)
                Config.save()
            end

            if sc or tc then
                local s = sc and newSpell or spell
                local t = tc and newTgt   or tgt
                gomRaw[i] = s ~= '' and joinGom(s, t) or 'null'
                Config.set('GoM', 'GoMSpell', gomRaw)
                Config.save()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        gomSize = gomSize + 1
        gomRaw[gomSize] = 'null'
        Config.set('GoM', 'GoMSize', tostring(gomSize))
        Config.set('GoM', 'GoMSpell', gomRaw)
        Config.save()
    end
end

function SpellsUI.init(state)
    _state = state
end

return SpellsUI
