-- ui/combat.lua — Combat tab: Melee, DPS, Debuff, Burn, Aggro, AE sub-tabs.

local mq = require('mq')
local Helpers    = require('modules.ui.helpers')
local Config     = Helpers.Config
local checkbox   = Helpers.checkbox
local intInput   = Helpers.intInput
local GLT_VALUES  = Helpers.GLT_VALUES
local GLT_LABELS  = Helpers.GLT_LABELS
local ATGT_VALUES = Helpers.ATGT_VALUES
local ATGT_LABELS = Helpers.ATGT_LABELS

local CombatUI = {}
local _state

-- ---------------------------------------------------------------------------
-- Melee panel
-- ---------------------------------------------------------------------------

function CombatUI.drawMelee()
    local s = _state

    -- Toggles
    checkbox('Melee', s.combat.meleeOn, function(v)
        s.combat.meleeOn = v
        Config.set('Melee', 'MeleeOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Auto-Acquire Targets', s.combat.targetSwitchingOn, function(v)
        s.combat.targetSwitchingOn = v
        Config.set('Melee', 'TargetSwitchingOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Manual Target Swapping', s.combat.manualTargetMode, function(_)
        mq.cmd('/katargetmode')
    end)

    checkbox('Use MQ2Melee', s.combat.useMQ2Melee, function(v)
        s.combat.useMQ2Melee = v
        Config.set('Melee', 'UseMQ2Melee', v and '1' or '0')
        Config.save()
    end)

    checkbox('AutoFire', (s.combat.autoFireOn or 0) ~= 0, function(_)
        mq.cmd('/autofireon')
    end)

    checkbox('LOS Check', Config.get('General', 'LOSBeforeCombat', '0') == '1', function(v)
        Config.set('General', 'LOSBeforeCombat', v and '1' or '0')
        Config.save()
    end)

    if s.session.iAmARogue then
        checkbox('Auto Hide', s.misc.autoHide, function(v)
            s.misc.autoHide = v
            Config.set('General', 'AutoHide', v and '1' or '0')
            Config.save()
        end)
    end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Assist %',    s.combat.assistAt,      1,  100, 'Melee', 'AssistAt',        function(v) s.combat.assistAt      = v end)
    intInput('Melee Dist',  s.combat.meleeDistance,  1,  500, 'Melee', 'MeleeDistance',   function(v) s.combat.meleeDistance = v end)
    local faceMobLabels = { 'Off', 'Fast (no camera)', 'Smooth (no camera)' }
    local faceMobIdx = (s.movement.faceMobOn or 0) + 1
    ImGui.PushItemWidth(200)
    local newFaceIdx, faceChanged = ImGui.Combo('Face Mob##facemob', faceMobIdx, faceMobLabels)
    if faceChanged then
        local newVal = newFaceIdx - 1
        s.movement.faceMobOn = newVal
        Config.set('Melee', 'FaceMobOn', tostring(newVal))
        Config.save()
    end
    ImGui.PopItemWidth()
    -- Stick style
    ImGui.Spacing()
    local stickValues = { '0', 'behind', 'front', '!front', 'moveback', 'pin', 'I' }
    local stickLabels = {
        'Default (plain stick)',
        'Behind target',
        'In front of target',
        'Not in front of target',
        'Move back to range',
        'Pin (no rotation)',
        'Disabled (no stick)',
    }
    local stickCurrent = s.movement.dStickHow or '0'
    local stickIdx = 1
    for i, v in ipairs(stickValues) do
        if v == stickCurrent then stickIdx = i break end
    end
    ImGui.PushItemWidth(200)
    local newIdx, changed = ImGui.Combo('Stick How##stickhow', stickIdx, stickLabels)
    if changed then
        local newVal = stickValues[newIdx] or '0'
        s.movement.dStickHow = newVal
        Config.set('Melee', 'StickHow', newVal)
        Config.save()
    end
    ImGui.PopItemWidth()
end

-- ---------------------------------------------------------------------------
-- DPS entry split/join
-- ---------------------------------------------------------------------------

local function splitDPS(raw)
    -- SpellName[|thresh[|target[|damod]]][|condNNN]  →  spell, thresh, target, damod, cond
    local spell, thresh, target, damod, cond = '', '0', '', '', ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell  = parts[1] or ''
    thresh = parts[2] or '0'
    target = parts[3] or ''
    damod  = parts[4] or ''
    return spell, thresh, target, damod, cond
end

local function joinDPS(spell, thresh, target, damod, cond)
    local result = spell .. '|' .. thresh
    if target ~= '' or damod ~= '' then result = result .. '|' .. target end
    if damod  ~= ''               then result = result .. '|' .. damod  end
    if cond   ~= ''               then result = result .. '|' .. cond   end
    return result
end

-- ---------------------------------------------------------------------------
-- Aggro panel
-- ---------------------------------------------------------------------------

local function splitAggro(raw)
    -- SpellName[|pct[|glt[|target]]][|condNNN]  →  spell, pct, glt, target, cond
    local spell, pct, glt, target, cond = '', '0', '<', '', ''
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell  = parts[1] or ''
    pct    = parts[2] or '0'
    glt    = parts[3] or '<'
    target = parts[4] or ''
    return spell, pct, glt, target, cond
end

local function joinAggro(spell, pct, glt, target, cond)
    local result = spell .. '|' .. pct .. '|' .. glt
    if target ~= '' then result = result .. '|' .. target end
    if cond   ~= '' then result = result .. '|' .. cond   end
    return result
end

function CombatUI.drawAggro()
    local s = _state

    checkbox('Aggro', s.combat.aggroOn, function(v)
        s.combat.aggroOn = v
        Config.set('Aggro', 'AggroOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local aggroRaw  = Config.get('Aggro', 'Aggro',     nil) or {}
    local aggroSize = tonumber(Config.get('Aggro', 'AggroSize', '10')) or 10

    local function syncAggroArray()
        s.combat.aggroArray = {}
        for _, slot in ipairs(Config.parseCondArray(aggroRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.combat.aggroArray[#s.combat.aggroArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('aggro_tbl', 6, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Pct',    ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('GtL',    ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, aggroSize do
            local raw     = aggroRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, pct, glt, target, cond = splitAggro(isEmpty and '' or raw)
            local newSpell, newPct, newGlt, newTarget, newCond = spell, pct, glt, target, cond
            local sc, pc, gc, tac, cc = false, false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##aspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local pctNum = tonumber(pct) or 0
            local newPctNum
            newPctNum, pc = ImGui.InputInt('##apct' .. i, pctNum)
            if pc then newPct = tostring(math.max(0, math.min(200, newPctNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local gltIdx = 1
            for k, v in ipairs(GLT_VALUES) do if v == glt then gltIdx = k; break end end
            local newGltIdx
            newGltIdx, gc = ImGui.Combo('##aglt' .. i, gltIdx, GLT_LABELS)
            if gc then newGlt = GLT_VALUES[newGltIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(ATGT_VALUES) do if v == target then targetIdx = k; break end end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##atgt' .. i, targetIdx, ATGT_LABELS)
            if tac then newTarget = ATGT_VALUES[newTargetIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##acond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##agrem' .. i) then
                if i == aggroSize and aggroSize > 1 then
                    aggroRaw[i] = nil
                    aggroSize   = aggroSize - 1
                    Config.set('Aggro', 'AggroSize', tostring(aggroSize))
                else
                    aggroRaw[i] = 'null'
                end
                Config.set('Aggro', 'Aggro', aggroRaw)
                Config.save()
                syncAggroArray()
            end

            if sc or pc or gc or tac or cc then
                local spellVal = sc and newSpell or spell
                aggroRaw[i] = spellVal ~= '' and joinAggro(
                    spellVal,
                    pc  and newPct    or pct,
                    gc  and newGlt    or glt,
                    tac and newTarget or target,
                    cc  and newCond   or cond
                ) or 'null'
                Config.set('Aggro', 'Aggro', aggroRaw)
                Config.save()
                syncAggroArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        aggroSize = aggroSize + 1
        aggroRaw[aggroSize] = 'null'
        Config.set('Aggro', 'AggroSize', tostring(aggroSize))
        Config.set('Aggro', 'Aggro', aggroRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Debuff panel
-- ---------------------------------------------------------------------------

function CombatUI.drawDebuffs()
    local s = _state

    local DEBUFF_ON_LABELS = { 'Off', 'In Combat', 'OOC Also' }
    local debuffOnIdx = (s.debuff.on or 0) + 1
    local newDebuffOnIdx, debuffOnChanged = ImGui.Combo('Debuff##debuffon', debuffOnIdx, DEBUFF_ON_LABELS)
    if debuffOnChanged then
        s.debuff.on = newDebuffOnIdx - 1
        Config.set('Debuff', 'DebuffOn', tostring(s.debuff.on))
        Config.save()
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local debuffRaw  = Config.get('Debuff', 'Debuff',     nil) or {}
    local debuffSize = tonumber(Config.get('Debuff', 'DebuffSize', '0')) or 0

    local function syncDebuffArray()
        s.debuff.slots = {}
        s.debuff.count = 0
        s.debuff.size  = debuffSize
        for i = 1, debuffSize do
            local raw = debuffRaw[i] or 'null'
            if raw ~= 'null' and raw ~= '' then
                local cond    = ''
                local condPos = raw:lower():find('|cond%d')
                if condPos then
                    cond = raw:sub(condPos + 1)
                    raw  = raw:sub(1, condPos - 1)
                end
                local spell  = raw
                local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
                if spell ~= '' then
                    s.debuff.slots[#s.debuff.slots + 1] = { spell = spell, condNo = condNo }
                    s.debuff.count = s.debuff.count + 1
                end
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('debuff_tbl', 3, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Cond',  ImGuiTableColumnFlags.WidthFixed,  160)
        ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, debuffSize do
            local raw     = debuffRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, cond = '', ''
            if not isEmpty then
                local condPos = raw:lower():find('|cond%d')
                if condPos then
                    cond = raw:sub(condPos + 1)
                    raw  = raw:sub(1, condPos - 1)
                end
                spell = raw
            end
            local newSpell, newCond = spell, cond
            local sc, cc = false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##dbspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##dbcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##dbrem' .. i) then
                if i == debuffSize and debuffSize > 1 then
                    debuffRaw[i] = nil
                    debuffSize   = debuffSize - 1
                    Config.set('Debuff', 'DebuffSize', tostring(debuffSize))
                else
                    debuffRaw[i] = 'null'
                end
                Config.set('Debuff', 'Debuff', debuffRaw)
                Config.save()
                syncDebuffArray()
            end

            if sc or cc then
                local spellVal = sc and newSpell or spell
                local condVal  = cc and newCond  or cond
                debuffRaw[i]   = spellVal ~= '' and (spellVal .. (condVal ~= '' and '|' .. condVal or '')) or 'null'
                Config.set('Debuff', 'Debuff', debuffRaw)
                Config.save()
                syncDebuffArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]##dbadd') then
        debuffSize = debuffSize + 1
        debuffRaw[debuffSize] = 'null'
        Config.set('Debuff', 'DebuffSize', tostring(debuffSize))
        Config.set('Debuff', 'Debuff', debuffRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- DPS rotation panel
-- ---------------------------------------------------------------------------

function CombatUI.drawDPS()
    local s = _state

    checkbox('DPS', s.combat.dpsOn, function(v)
        s.combat.dpsOn = v
        Config.set('DPS', 'DPSOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('DPS Skip %',   s.combat.dpsSkip,     0,  100, 'DPS', 'DPSSkip',     function(v) s.combat.dpsSkip     = v end)
    intInput('DPS Interval', s.combat.dpsInterval, 0, 3600, 'DPS', 'DPSInterval', function(v) s.combat.dpsInterval = v end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local dpsRaw  = Config.get('DPS', 'DPS',     nil) or {}
    local dpsSize = tonumber(Config.get('DPS', 'DPSSize', '20')) or 20

    local function syncDpsArray()
        s.combat.dpsArray = {}
        for _, slot in ipairs(Config.parseCondArray(dpsRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.combat.dpsArray[#s.combat.dpsArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('dps_tbl', 6, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('HP%',    ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('DAMod',  ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, dpsSize do
            local raw     = dpsRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, thresh, target, damod, cond = splitDPS(isEmpty and '' or raw)
            local newSpell, newThresh, newTarget, newDamod, newCond = spell, thresh, target, damod, cond
            local sc, tc, tac, dc, cc = false, false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##dspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local threshNum = tonumber(thresh) or 0
            local newThreshNum
            newThreshNum, tc = ImGui.InputInt('##dthresh' .. i, threshNum)
            if tc then newThresh = tostring(math.max(0, math.min(100, newThreshNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(ATGT_VALUES) do if v == target then targetIdx = k; break end end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##dtgt' .. i, targetIdx, ATGT_LABELS)
            if tac then newTarget = ATGT_VALUES[newTargetIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newDamod, dc = ImGui.InputText('##ddamod' .. i, damod, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##dcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##drem' .. i) then
                if i == dpsSize and dpsSize > 1 then
                    dpsRaw[i] = nil
                    dpsSize   = dpsSize - 1
                    Config.set('DPS', 'DPSSize', tostring(dpsSize))
                else
                    dpsRaw[i] = 'null'
                end
                Config.set('DPS', 'DPS', dpsRaw)
                Config.save()
                syncDpsArray()
            end

            if sc or tc or tac or dc or cc then
                local spellVal = sc and newSpell or spell
                dpsRaw[i] = spellVal ~= '' and joinDPS(
                    spellVal,
                    tc  and newThresh  or thresh,
                    tac and newTarget  or target,
                    dc  and newDamod   or damod,
                    cc  and newCond    or cond
                ) or 'null'
                Config.set('DPS', 'DPS', dpsRaw)
                Config.save()
                syncDpsArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        dpsSize = dpsSize + 1
        dpsRaw[dpsSize] = 'null'
        Config.set('DPS', 'DPSSize', tostring(dpsSize))
        Config.set('DPS', 'DPS', dpsRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- Burn rotation panel
-- ---------------------------------------------------------------------------

-- .mac Burn layout: SpellName|Target[|condNNN] (mac:11788-11816)
local BURN_TARGETS = { 'Mob', 'Me', 'MA', 'Pet' }

local function joinBurn(spell, target, condNo)
    local result = spell .. '|' .. (target ~= '' and target or 'Mob')
    if condNo > 0 then result = result .. '|' .. string.format('cond%d', condNo) end
    return result
end

function CombatUI.drawBurn()
    local s = _state

    checkbox('Burn', s.combat.burnOn, function(v)
        s.combat.burnOn = v
        Config.set('Burn', 'BurnOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Use Tribute', s.combat.useTribute, function(v)
        s.combat.useTribute = v
        Config.set('Burn', 'UseTribute', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    local burnNamedLabels = { 'Off', 'Burn all named', 'Burn watch list only' }
    local burnNamedIdx = (s.combat.burnAllNamed or 0) + 1
    ImGui.PushItemWidth(200)
    local newBurnIdx, burnChanged = ImGui.Combo('Burn Named##burnnamed', burnNamedIdx, burnNamedLabels)
    if burnChanged then
        local newVal = newBurnIdx - 1
        s.combat.burnAllNamed = newVal
        Config.set('Burn', 'BurnAllNamed', tostring(newVal))
        Config.save()
    end
    ImGui.PopItemWidth()

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local burnRaw  = Config.get('Burn', 'Burn',     nil) or {}
    local burnSize = tonumber(Config.get('Burn', 'BurnSize', '15')) or 15

    -- Cast.doBurn consumes raw entry strings (same as Combat.init), not parsed slot tables.
    local function syncBurnArray()
        s.combat.burnArray = {}
        for i = 1, burnSize do
            local v = burnRaw[i]
            if v and v ~= '' and v:lower() ~= 'null' then
                s.combat.burnArray[#s.combat.burnArray + 1] = v
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('burn_tbl', 4, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, burnSize do
            local raw     = burnRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, target, condNo = '', 'Mob', 0
            if not isEmpty then spell, target, condNo = Config.parseBurnEntry(raw) end
            local newSpell, newTarget, newCondNo = spell, target, condNo
            local sc, tac, cc = false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##bspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(BURN_TARGETS) do
                if v:lower() == target:lower() then targetIdx = k; break end
            end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##btgt' .. i, targetIdx, BURN_TARGETS)
            if tac then newTarget = BURN_TARGETS[newTargetIdx] or 'Mob' end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            if cc then newCondNo = newCondIdx - 1 end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##brem' .. i) then
                if i == burnSize and burnSize > 1 then
                    burnRaw[i] = nil
                    burnSize   = burnSize - 1
                    Config.set('Burn', 'BurnSize', tostring(burnSize))
                else
                    burnRaw[i] = 'null'
                end
                Config.set('Burn', 'Burn', burnRaw)
                Config.save()
                syncBurnArray()
            end

            if sc or tac or cc then
                local spellVal = sc and newSpell or spell
                burnRaw[i] = spellVal ~= '' and joinBurn(spellVal, newTarget, newCondNo) or 'null'
                Config.set('Burn', 'Burn', burnRaw)
                Config.save()
                syncBurnArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        burnSize = burnSize + 1
        burnRaw[burnSize] = 'null'
        Config.set('Burn', 'BurnSize', tostring(burnSize))
        Config.set('Burn', 'Burn', burnRaw)
        Config.save()
    end
end

-- ---------------------------------------------------------------------------
-- AE rotation panel
-- ---------------------------------------------------------------------------

local AE_TARGETS = { 'Mob', 'Single', 'Me', 'MA', 'Pet' }

local function splitAE(raw)
    -- "SpellName|MobCount|Target[|condNNN]" → spell, count, target, cond
    local spell, count, target, cond = '', '1', 'Mob', ''
    if not raw or raw == 'null' or raw == '' then return spell, count, target, cond end
    local condPos = raw:lower():find('|cond%d')
    if condPos then
        cond = raw:sub(condPos + 1)
        raw  = raw:sub(1, condPos - 1)
    end
    local parts = {}
    for p in (raw .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
    spell  = parts[1] or ''
    count  = parts[2] or '1'
    target = parts[3] or 'Mob'
    return spell, count, target, cond
end

local function joinAE(spell, count, target, cond)
    local result = spell .. '|' .. count .. '|' .. target
    if cond ~= '' then result = result .. '|' .. cond end
    return result
end

function CombatUI.drawAE()
    local s = _state

    checkbox('AE On', s.combat.aeOn, function(v)
        s.combat.aeOn = v
        Config.set('AE', 'AEOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('AE Radius', s.combat.aeRadius, 10, 500, 'AE', 'AERadius',
        function(v) s.combat.aeRadius = v end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    local aeRaw  = Config.get('AE', 'AE',     nil) or {}
    local aeSize = tonumber(Config.get('AE', 'AESize', '10')) or 10

    local function syncAEArray()
        s.combat.aeArray = {}
        for i = 1, aeSize do
            local v = aeRaw[i] or 'null'
            if v ~= 'null' and v ~= '' then s.combat.aeArray[i] = v end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('Cond%d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('ae_tbl', 5, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Count',  ImGuiTableColumnFlags.WidthFixed,   80)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,   75)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,  160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, aeSize do
            local raw     = aeRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, count, target, cond = splitAE(isEmpty and '' or raw)
            local newSpell, newCount, newTarget, newCond = spell, count, target, cond
            local sc, nc, tac, cc = false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##aespell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local countVal    = tonumber(count) or 1
            local newCountVal
            newCountVal, nc = ImGui.InputInt('##aecount' .. i, countVal, 1, 5)
            if nc then newCount = tostring(math.max(1, newCountVal)) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local tgtIdx = 0
            for j, v in ipairs(AE_TARGETS) do
                if v:upper() == target:upper() then tgtIdx = j - 1 break end
            end
            local newTgtIdx
            newTgtIdx, tac = ImGui.Combo('##aetgt' .. i, tgtIdx, AE_TARGETS)
            newTarget = AE_TARGETS[newTgtIdx + 1] or 'Mob'
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:lower():match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##aecond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%d', newCondIdx - 1)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            if ImGui.Button('[-]##aerem' .. i) then
                if i == aeSize and aeSize > 1 then
                    aeRaw[i] = nil
                    aeSize   = aeSize - 1
                    Config.set('AE', 'AESize', tostring(aeSize))
                else
                    aeRaw[i] = 'null'
                end
                Config.set('AE', 'AE', aeRaw)
                Config.save()
                syncAEArray()
            end

            if sc or nc or tac or cc then
                local sp = sc  and newSpell  or spell
                local ct = nc  and newCount  or count
                local tg = tac and newTarget or target
                local cn = cc  and newCond   or cond
                aeRaw[i] = sp ~= '' and joinAE(sp, ct, tg, cn) or 'null'
                Config.set('AE', 'AE', aeRaw)
                Config.save()
                syncAEArray()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        aeSize = aeSize + 1
        aeRaw[aeSize] = 'null'
        Config.set('AE', 'AESize', tostring(aeSize))
        Config.set('AE', 'AE', aeRaw)
        Config.save()
    end
end

function CombatUI.init(state)
    _state = state
end

return CombatUI
