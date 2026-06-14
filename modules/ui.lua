-- ui.lua — ImGui status and control panel.
-- Registered with mq.imgui.init; drawn each frame by the MQ2Lua runtime.
-- Reads State.* for display; writes go through existing bind toggle functions
-- so UI and /ka* chat commands stay in sync.

local mq = require('mq')

local AF_LABELS = { [0]='OFF', [1]='RANGED', [2]='PAUSED' }
local GLT_VALUES  = { '<', '<<', '>' }
local GLT_LABELS  = { '< gain', '<< sec', '> lose' }
local ATGT_VALUES = { '', 'me', 'ma', 'pet', 'inc', 'weave', 'mash', 'ambush' }
local ATGT_LABELS = { 'current', 'me', 'ma', 'pet', 'inc', 'weave', 'mash', 'ambush' }
local AF_COLORS = {
    [0] = {0.6, 0.6, 0.6},
    [1] = {0.4, 1.0, 0.4},
    [2] = {1.0, 0.9, 0.1},
}
local AFK_MODE_LABELS   = { 'Off', 'Stranger + GM', 'Stranger only', 'GM only' }
local AFK_ACTION_LABELS = { 'Hold until GM leaves', 'End macro', 'Unload MQ2', 'Quit EQ' }
local MEZ_MODE_LABELS   = { 'Off', 'Single + AE', 'Single only', 'AE only' }

local Config = require('modules.config')

local UI = {}
local _state, _cond
local _open = true
local COL    = 130  -- column width for checkbox SameLine and button widths
local _savedFullW, _savedFullH = 0, 0  -- window size saved before entering mini mode
local _pendingW,   _pendingH   = 0, 0  -- next-frame SetNextWindowSize values (0 = no pending)
local MINI_W, MINI_H           = 465, 0

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

local function drawStatus()
    local s = _state
    local C2, C3 = 160, 320  -- fixed column offsets (px from window left edge)

    -- Combat state label + color
    local combatLabel, cr, cg, cb
    if s.session.iAmDead then
        combatLabel, cr, cg, cb = 'DEAD',      1.0, 0.2, 0.2
    elseif s.combat.combatStart then
        combatLabel, cr, cg, cb = 'FIGHTING',  1.0, 0.4, 0.4
    elseif s.pull.pulling then
        combatLabel, cr, cg, cb = 'PULLING',   1.0, 0.9, 0.1
    elseif s.movement.returnToCamp then
        combatLabel, cr, cg, cb = 'RETURNING', 1.0, 0.7, 0.2
    elseif s.heal.medding then
        combatLabel, cr, cg, cb = 'MEDDING',   0.4, 0.8, 1.0
    elseif s.session.chaseAssist then
        local who = (s.movement.whoToChase or ''):sub(1, 10)
        combatLabel, cr, cg, cb = 'CHASING ' .. who, 0.8, 0.6, 1.0
    else
        combatLabel, cr, cg, cb = 'IDLE',      0.4, 1.0, 0.4
    end

    -- Row 1: role | MA
    ImGui.Text('Role: ' .. (s.session.role or ''))
    ImGui.SameLine(C2)
    ImGui.Text('MA: ' .. (s.session.mainAssist or ''))

    -- Row 2: state | burn | autofire
    ImGui.Text('State:')
    ImGui.SameLine()
    ImGui.TextColored(cr, cg, cb, 1.0, combatLabel)
    ImGui.SameLine(C2)
    ImGui.Text('Burn: ' .. (s.combat.burnOn and 'ON' or 'OFF'))
    ImGui.SameLine(C3)
    local af = s.combat.autoFireOn or 0
    local afc = AF_COLORS[af]
    ImGui.Text('AutoFire:')
    ImGui.SameLine()
    ImGui.TextColored(afc[1], afc[2], afc[3], 1.0, AF_LABELS[af])

    -- Row 3: target | mobs | aggro
    local targetName = ''
    local aggroID = tonumber(s.combat.aggroTargetID) or 0
    if aggroID > 0 then
        targetName = (mq.TLO.Spawn(aggroID).CleanName() or ''):sub(1, 14)
    end
    ImGui.Text('Target: ' .. targetName)
    ImGui.SameLine(C2)
    ImGui.Text('Mobs: ' .. tostring(s.combat.mobCount or 0))
    ImGui.SameLine(C3)
    ImGui.Text('Aggro:')
    ImGui.SameLine()
    if (mq.TLO.Me.Level() or 0) < 20 then
        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, 'N/A')
    else
        local pctAggro = mq.TLO.Me.PctAggro() or 0
        local ar, ag, ab
        if     pctAggro >= 100 then ar, ag, ab = 0.2, 1.0, 0.2
        elseif pctAggro >= 75  then ar, ag, ab = 1.0, 0.9, 0.1
        else                        ar, ag, ab = 1.0, 0.3, 0.3
        end
        ImGui.TextColored(ar, ag, ab, 1.0, pctAggro .. '%')
    end

    -- Row 4: camp coords | radius
    local mv = s.movement
    local isPuller = ({ puller=true, pullertank=true, pullerpettank=true,
                        hunter=true, hunterpettank=true })[s.session.role or '']
    if isPuller and (mv.campX or 0) == 0 and (mv.campY or 0) == 0 then
        ImGui.TextColored(1.0, 0.2, 0.2, 1.0, 'No Camp Set — run /makecamphere')
    else
        local rtc = mv.returnToCamp and '  [RTC]' or ''
        ImGui.Text(string.format('Camp: (%.0f, %.0f, %.0f)', mv.campY or 0, mv.campX or 0, mv.campZ or 0))
        ImGui.SameLine(C2)
        ImGui.Text(string.format('Radius: %d%s', mv.campRadius or 0, rtc))
        ImGui.SameLine(C3)
        local campZoneName = mv.campZoneName or ''
        local curZone      = s.session.zoneName or ''
        if campZoneName ~= '' and campZoneName ~= curZone then
            ImGui.Text('Zone: ' .. curZone .. ' (camp: ' .. campZoneName .. ')')
        else
            ImGui.Text('Zone: ' .. curZone)
        end
    end

    -- Row 5 (charm classes only): charmed mob
    if s.session.iAmACharmClass and (s.charm.petId or 0) > 0 then
        local charmName = mq.TLO.Spawn(s.charm.petId).CleanName() or '???'
        ImGui.Text('Charmed:')
        ImGui.SameLine()
        ImGui.TextColored(1.0, 0.6, 0.2, 1.0, charmName)
    end
end

-- ---------------------------------------------------------------------------
-- Toggle Controls panel
-- ---------------------------------------------------------------------------

local function checkbox(label, value, onChange)
    local W, H = 40, 20
    local cx, cy = ImGui.GetCursorScreenPos()
    local dl = ImGui.GetWindowDrawList()
    ImGui.InvisibleButton('##tog_' .. label, W, H)
    if ImGui.IsItemClicked() then onChange(not value) end
    local col = value
        and ImGui.GetColorU32(0.2, 0.78, 0.35, 1.0)
        or  ImGui.GetColorU32(0.45, 0.45, 0.45, 1.0)
    dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + W, cy + H), col, H * 0.5)
    local knobX = value and (cx + W - H * 0.5) or (cx + H * 0.5)
    dl:AddCircleFilled(ImVec2(knobX, cy + H * 0.5), H * 0.5 - 2, 0xFFFFFFFF)
    ImGui.SameLine()
    ImGui.Text(label)
end

local function intInput(label, value, min, max, configSection, configKey, stateSet)
    local newVal = ImGui.InputInt(label, value)
    if newVal ~= value then
        newVal = math.max(min, math.min(max, newVal))
        stateSet(newVal)
        Config.set(configSection, configKey, tostring(newVal))
        Config.save()
    end
end

local function drawControls()
    local s = _state

    checkbox('Loot', s.loot.on ~= 0, function(v)
        mq.cmd(v and '/kalooton' or '/kalootoff')
    end)

    -- Camp & Movement
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text('Camp / Movement')
    if ImGui.Button('Make Camp Here', COL, 0) then mq.cmd('/makecamphere') end
    ImGui.SameLine()
    if ImGui.Button('Camp Off',       COL, 0) then mq.cmd('/campoff')      end
    if ImGui.Button('Chase Me',       COL, 0) then mq.cmd('/chaseme')      end
    ImGui.SameLine()
    if ImGui.Button('Stay Here',      COL, 0) then mq.cmd('/stayhere')     end

    local campSet = s.movement.campX ~= 0 or s.movement.campY ~= 0
    if not campSet then ImGui.BeginDisabled() end
    checkbox('Return to Camp', s.movement.returnToCamp, function(v)
        s.movement.returnToCamp = v
    end)
    if not campSet then ImGui.EndDisabled() end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Camp Radius', s.movement.campRadius,  1, 1000, 'General', 'CampRadius', function(v) s.movement.campRadius = v end)
    intInput('Med Start %', s.heal.medStart,        1,  100, 'General', 'MedStart',   function(v) s.heal.medStart       = v end)
    intInput('Med Stop %',  s.heal.medStop,         1,  100, 'General', 'MedStop',    function(v) s.heal.medStop        = v end)
end

-- ---------------------------------------------------------------------------
-- Pull panel
-- ---------------------------------------------------------------------------

local function drawPull()
    local s = _state

    -- Toggles
    checkbox('Pull', not s.pull.hold, function(v)
        s.pull.hold = not v
    end)
    ImGui.SameLine(160)
    checkbox('Chain Pull', s.pull.chainPull ~= 0, function(v)
        s.pull.chainPull = v and 1 or 0
        Config.set('Pull', 'ChainPull', v and '1' or '0')
        Config.save()
    end)

    checkbox('Pull On Return', s.pull.pullOnReturn, function(v)
        s.pull.pullOnReturn = v
        Config.set('Pull', 'PullOnReturn', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(160)
    checkbox('Waypoint Pull', s.pull.pullLocsOn, function(v)
        s.pull.pullLocsOn = v
        Config.set('PullAdvanced', 'PullLocsOn', v and '1' or '0')
        Config.save()
    end)

    if s.session.iAmABard then
        checkbox('Twist On Pull', s.bard.pullTwistOn, function(v)
            s.bard.pullTwistOn = v
            Config.set('Pull', 'PullTwistOn', v and '1' or '0')
            Config.save()
        end)
    end

    -- Numeric settings
    ImGui.Spacing()
    ImGui.Separator()
    intInput('Max Radius',  s.pull.maxRadius,    1, 2000, 'Pull', 'MaxRadius',    function(v) s.pull.maxRadius    = v end)
    intInput('Max Z Range', s.pull.maxZRange,    1, 2000, 'Pull', 'MaxZRange',    function(v) s.pull.maxZRange    = v end)
    intInput('Pull Range',  s.pull.range,         1,  500, 'Pull', 'PullRange',    function(v) s.pull.range        = v end)
    intInput('Arc Width°',  s.pull.pullArcWidth,  0,  360, 'Pull', 'PullArcWidth', function(v) s.pull.pullArcWidth = v end)

    -- Read-only status
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text('Pull With: ' .. (s.pull.withAlt or 'Melee'))
end

-- ---------------------------------------------------------------------------
-- Melee panel
-- ---------------------------------------------------------------------------

local function drawMelee()
    local s = _state

    -- Toggles
    checkbox('Melee', s.combat.meleeOn, function(v)
        s.combat.meleeOn = v
        Config.set('Melee', 'MeleeOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Target Switch', s.combat.targetSwitchingOn, function(v)
        s.combat.targetSwitchingOn = v
        Config.set('Melee', 'TargetSwitchingOn', v and '1' or '0')
        Config.save()
    end)

    checkbox('Manual Target', s.combat.manualTargetMode, function(_)
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

local function drawHealThresholds()
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
        condLabels[j + 1] = string.format('cond%03d', j)
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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##hcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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
-- Spell Slots panel
-- ---------------------------------------------------------------------------

local LSS_LABELS = { 'Off', 'Named Set', 'From INI' }

local function drawSpellSlots()
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
-- Pet panel
-- ---------------------------------------------------------------------------

local function drawPet()
    local s = _state

    if ImGui.BeginTabBar('KAPetTabs') then
        -- Controls sub-tab
        if ImGui.BeginTabItem('Controls##pet') then
            ImGui.Spacing()

            -- Row 1
            checkbox('Pet', s.pet.on, function(v)
                mq.cmd(v and '/peton' or '/petoff')
            end)
            ImGui.SameLine(120)
            checkbox('Pet Buffs', s.buffs.petBuffsOn, function(v)
                s.buffs.petBuffsOn = v
                Config.set('Pet', 'PetBuffsOn', v and '1' or '0')
                Config.save()
            end)

            -- Row 2
            checkbox('Shrink', s.pet.shrinkOn, function(v)
                s.pet.shrinkOn = v
                Config.set('Pet', 'PetShrinkOn', v and '1' or '0')
                Config.save()
            end)
            ImGui.SameLine(120)
            checkbox('Toys', s.pet.toysOn, function(v)
                s.pet.toysOn = v
                Config.set('Pet', 'PetToysOn', v and '1' or '0')
                Config.save()
            end)

            -- Row 3
            checkbox('Suspend', s.pet.suspend, function(v)
                s.pet.suspend = v
                Config.set('Pet', 'PetSuspend', v and '1' or '0')
                Config.save()
            end)
            ImGui.SameLine(120)
            checkbox('Hold', s.pet.holdOn ~= 0, function(v)
                s.pet.holdOn = v and 1 or 0
                Config.set('Pet', 'PetHoldOn', v and '1' or '0')
                Config.save()
            end)

            -- Row 4
            checkbox('Taunt Off', s.pet.tauntOverride, function(v)
                s.pet.tauntOverride = v
                Config.set('Pet', 'PetTauntOverride', v and '1' or '0')
                Config.save()
            end)

            -- Editable spell fields
            ImGui.Spacing()
            ImGui.Separator()
            ImGui.PushItemWidth(200)
            local spellVal, spellChanged = ImGui.InputText('Pet Spell##petspell', s.pet.spell, 0)
            if spellChanged and spellVal ~= s.pet.spell then
                s.pet.spell = spellVal
                Config.set('Pet', 'PetSpell', spellVal)
                Config.save()
            end
            if s.pet.shrinkOn then
                local shrinkVal, shrinkChanged = ImGui.InputText('Shrink Spell##shrinkspell', s.pet.shrinkSpell, 0)
                if shrinkChanged and shrinkVal ~= s.pet.shrinkSpell then
                    s.pet.shrinkSpell = shrinkVal
                    Config.set('Pet', 'PetShrinkSpell', shrinkVal)
                    Config.save()
                end
            end
            ImGui.PopItemWidth()
            ImGui.EndTabItem()
        end

        -- Pet Buffs sub-tab
        if ImGui.BeginTabItem('Pet Buffs##pet') then
            ImGui.Spacing()

            local petBuffsRaw  = Config.get('Pet', 'PetBuffs',     nil) or {}
            local petBuffsSize = tonumber(Config.get('Pet', 'PetBuffsSize', '5')) or 5

            local function syncPetBuffsArray()
                s.buffs.petBuffsArray = {}
                for _, slot in ipairs(Config.parseCondArray(petBuffsRaw)) do
                    if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                        s.buffs.petBuffsArray[#s.buffs.petBuffsArray + 1] = slot
                    end
                end
            end

            local pbTblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
            if ImGui.BeginTable('petbuffs_tbl', 2, pbTblFlags) then
                ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
                ImGui.TableSetupColumn('',      ImGuiTableColumnFlags.WidthFixed,    32)
                ImGui.TableHeadersRow()

                for i = 1, petBuffsSize do
                    local raw     = petBuffsRaw[i] or 'null'
                    local isEmpty = (raw == 'null' or raw == '')
                    local spell   = isEmpty and '' or raw

                    ImGui.TableNextColumn()
                    ImGui.PushItemWidth(-1)
                    local newSpell, sc = ImGui.InputText('##pbspell' .. i, spell, 0)
                    ImGui.PopItemWidth()

                    ImGui.TableNextColumn()
                    if ImGui.Button('[-]##pbrem' .. i) then
                        if i == petBuffsSize and petBuffsSize > 1 then
                            petBuffsRaw[i] = nil
                            petBuffsSize   = petBuffsSize - 1
                            Config.set('Pet', 'PetBuffsSize', tostring(petBuffsSize))
                        else
                            petBuffsRaw[i] = 'null'
                        end
                        Config.set('Pet', 'PetBuffs', petBuffsRaw)
                        Config.save()
                        syncPetBuffsArray()
                    end

                    if sc then
                        petBuffsRaw[i] = newSpell ~= '' and newSpell or 'null'
                        Config.set('Pet', 'PetBuffs', petBuffsRaw)
                        Config.save()
                        syncPetBuffsArray()
                    end
                end
                ImGui.EndTable()
            end

            ImGui.Spacing()
            if ImGui.Button('[+ Add]##pbuffsadd') then
                petBuffsSize = petBuffsSize + 1
                petBuffsRaw[petBuffsSize] = 'null'
                Config.set('Pet', 'PetBuffsSize', tostring(petBuffsSize))
                Config.set('Pet', 'PetBuffs', petBuffsRaw)
                Config.save()
            end
            ImGui.EndTabItem()
        end

        -- Pet Toys sub-tab
        if ImGui.BeginTabItem('Pet Toys##pet') then
            ImGui.Spacing()

            local petToysRaw  = Config.get('Pet', 'PetToys',     nil) or {}
            local petToysSize = tonumber(Config.get('Pet', 'PetToysSize', '5')) or 5

            local function syncPetToysArray()
                s.pet.toysArray = {}
                for _, v in ipairs(petToysRaw) do
                    if v and v ~= '' and v ~= 'null' then
                        s.pet.toysArray[#s.pet.toysArray + 1] = v
                    end
                end
            end

            local ptTblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
            if ImGui.BeginTable('pettoys_tbl', 2, ptTblFlags) then
                ImGui.TableSetupColumn('Item', ImGuiTableColumnFlags.WidthStretch, 0)
                ImGui.TableSetupColumn('',     ImGuiTableColumnFlags.WidthFixed,    32)
                ImGui.TableHeadersRow()

                for i = 1, petToysSize do
                    local raw     = petToysRaw[i] or 'null'
                    local isEmpty = (raw == 'null' or raw == '')
                    local item    = isEmpty and '' or raw

                    ImGui.TableNextColumn()
                    ImGui.PushItemWidth(-1)
                    local newItem, ic = ImGui.InputText('##ptitem' .. i, item, 0)
                    ImGui.PopItemWidth()

                    ImGui.TableNextColumn()
                    if ImGui.Button('[-]##ptrem' .. i) then
                        if i == petToysSize and petToysSize > 1 then
                            petToysRaw[i] = nil
                            petToysSize   = petToysSize - 1
                            Config.set('Pet', 'PetToysSize', tostring(petToysSize))
                        else
                            petToysRaw[i] = 'null'
                        end
                        Config.set('Pet', 'PetToys', petToysRaw)
                        Config.save()
                        syncPetToysArray()
                    end

                    if ic then
                        petToysRaw[i] = newItem ~= '' and newItem or 'null'
                        Config.set('Pet', 'PetToys', petToysRaw)
                        Config.save()
                        syncPetToysArray()
                    end
                end
                ImGui.EndTable()
            end

            ImGui.Spacing()
            if ImGui.Button('[+ Add]##ptoysadd') then
                petToysSize = petToysSize + 1
                petToysRaw[petToysSize] = 'null'
                Config.set('Pet', 'PetToysSize', tostring(petToysSize))
                Config.set('Pet', 'PetToys', petToysRaw)
                Config.save()
            end
            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end
end

-- ---------------------------------------------------------------------------
-- Merc panel
-- ---------------------------------------------------------------------------

local function drawMerc()
    local s = _state

    checkbox('Merc', s.merc.on ~= 0, function(v)
        s.merc.on = v and 1 or 0
        Config.set('Merc', 'MercOn', v and '1' or '0')
        Config.save()
    end)

    intInput('Assist %', s.merc.assistAt, 1, 100, 'Merc', 'MercAssistAt',
        function(v) s.merc.assistAt = v end)

    ImGui.Spacing()
    ImGui.Separator()

    -- Live status
    local mercName  = s.merc.myMerc ~= '' and s.merc.myMerc or '(none)'
    local mercState = mq.TLO.Mercenary.State() or ''
    local sr, sg, sb
    if mercState == 'Active' then
        sr, sg, sb = 0.2, 1.0, 0.2
    elseif mercState == 'DEAD' then
        sr, sg, sb = 1.0, 0.2, 0.2
    else
        sr, sg, sb = 1.0, 0.9, 0.1
    end

    ImGui.Text('Name:  ' .. mercName)
    ImGui.Text('State: ')
    ImGui.SameLine()
    ImGui.TextColored(sr, sg, sb, 1.0, mercState ~= '' and mercState or 'Unknown')

    local assistID   = tonumber(s.merc.assisting) or 0
    local assistName = assistID > 0 and (mq.TLO.Spawn(assistID).CleanName() or '') or ''
    ImGui.Text('Assist: ' .. (assistName ~= '' and assistName or '—'))
end

-- ---------------------------------------------------------------------------
-- Bard panel (class-gated)
-- ---------------------------------------------------------------------------

-- Render an editable song list for one MQ2Medley set.
-- songs: the State.bard.*Songs array (mutated in place).
-- setName: the MQ2Medley section name (e.g. 'ooc').
local function drawSongSet(songs, setName)
    local bard = _state.bard
    local changed = false

    ImGui.PushItemWidth(300)
    for i = 1, #songs do
        local cur = songs[i] or ''
        local newVal, edited = ImGui.InputText(string.format('##song_%s_%d', setName, i), cur, 0)
        if edited and newVal ~= cur then
            songs[i] = newVal ~= '' and newVal or nil
            changed = true
        end
        ImGui.SameLine()
        if ImGui.Button('[-]##songrem_' .. setName .. '_' .. i) then
            if i == #songs and #songs > 1 then
                songs[i] = nil
            else
                -- Non-trailing remove: compact the array
                table.remove(songs, i)
            end
            changed = true
        end
    end
    ImGui.PopItemWidth()

    ImGui.Spacing()
    local maxSongs = mq.TLO.Me.NumGems() or 13
    local atMax = #songs >= maxSongs
    if atMax then ImGui.BeginDisabled() end
    if ImGui.Button('[+ Add]##songadd_' .. setName) then
        songs[#songs + 1] = ''
        -- Don't save on add — user types the name then it saves on edit
    end
    if atMax then ImGui.EndDisabled() end
    ImGui.SameLine()
    if ImGui.Button('Apply##songapply_' .. setName) then
        changed = true  -- force save even without text change (e.g. after Add)
    end

    if changed and bard.saveSongSet then
        -- Strip empty entries before saving.
        local clean = {}
        for _, s in ipairs(songs) do
            if s and s ~= '' then clean[#clean + 1] = s end
        end
        -- Rebuild the live array to match.
        for k in pairs(songs) do songs[k] = nil end
        for i, s in ipairs(clean) do songs[i] = s end
        bard.saveSongSet(setName, clean)
    end
end

local function drawBard()
    ---@diagnostic disable-next-line: undefined-field
    local Medley   = mq.TLO.Medley
    local bard     = _state.bard
    local active    = Medley and (Medley.Active() or false) or false
    local activeSet = Medley and (Medley.Medley() or '—') or '—'

    ImGui.Text(string.format('Active set: %s  (%s)', activeSet, active and 'playing' or 'stopped'))
    ImGui.Separator()

    -- Set switch buttons
    if ImGui.Button(bard.meleeMedley) then mq.cmdf('/medley %s', bard.meleeMedley) end
    ImGui.SameLine()
    if ImGui.Button(bard.burnMedley)  then mq.cmdf('/medley %s', bard.burnMedley)  end
    ImGui.SameLine()
    if ImGui.Button(bard.oocMedley)   then mq.cmdf('/medley %s', bard.oocMedley)   end

    -- Start / Stop
    ImGui.Spacing()
    if ImGui.Button('Start') then
        _state.bard.manualStop  = false
        _state.bard.twisting    = false
        _state.bard.dpsTwisting = false
        mq.cmd('/medley start')
    end
    ImGui.SameLine()
    if ImGui.Button('Stop') then
        _state.bard.manualStop = true
        mq.cmd('/medley stop')
    end

    -- Song set editor sub-tabs
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    if not bard.mqIniPath then
        ImGui.TextColored(1, 1, 0, 1, 'MQ2 char INI not found — song set editor unavailable.')
        ImGui.TextDisabled('Expected ServerName_CharName.ini in MQ2 config directory.')
        return
    end

    local sets = {
        { label = 'OOC',   songs = bard.oocSongs,   setName = bard.oocMedley   },
        { label = 'Melee', songs = bard.meleeSongs, setName = bard.meleeMedley },
        { label = 'Burn',  songs = bard.burnSongs,  setName = bard.burnMedley  },
        { label = 'GoM',   songs = bard.gomSongs,   setName = bard.gomMedley   },
    }

    if ImGui.BeginTabBar('BardSongSets') then
        for _, set in ipairs(sets) do
            if ImGui.BeginTabItem(set.label) then
                ImGui.Spacing()
                if #set.songs == 0 then
                    ImGui.TextDisabled(string.format('No songs in [MQ2Medley-%s]. Use [+ Add] to add one.', set.setName))
                    ImGui.Spacing()
                    if ImGui.Button('[+ Add]##songadd_' .. set.setName) then
                        set.songs[1] = ''
                    end
                else
                    drawSongSet(set.songs, set.setName)
                end
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    end
end

-- ---------------------------------------------------------------------------
-- Conditions panel
-- ---------------------------------------------------------------------------

local function drawConditions()
    local s = _state

    checkbox('Conditions On', s.cond.on, function(v)
        s.cond.on = v
        Config.set('KConditions', 'ConOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    -- Conditions are stored as an indexed array under the 'Cond' key.
    local condArr = Config.get('KConditions', 'Cond', nil) or {}

    if ImGui.BeginTable('##condtbl', 4, 0) then
        ImGui.TableSetupColumn('Expression', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Label',      ImGuiTableColumnFlags.WidthFixed,   68)
        ImGui.TableSetupColumn('Now',        ImGuiTableColumnFlags.WidthFixed,   28)
        ImGui.TableSetupColumn('',           ImGuiTableColumnFlags.WidthFixed,   32)
        ImGui.TableHeadersRow()

        for i = 1, (s.cond.size or 5) do
            local current = s.cond.expressions[i] or ''
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0)
            ImGui.PushItemWidth(-1)
            local newVal, changed = ImGui.InputText('##cond' .. i, current, 0)
            ImGui.PopItemWidth()
            if changed and newVal ~= current then
                s.cond.expressions[i] = newVal ~= '' and newVal or nil
                condArr[i] = newVal ~= '' and newVal or 'null'
                Config.set('KConditions', 'Cond', condArr)
                Config.save()
            end
            ImGui.TableSetColumnIndex(1)
            ImGui.Text(string.format('Cond %03d', i))
            ImGui.TableSetColumnIndex(2)
            if current ~= '' and _cond then
                local ok = _cond.evalStr(current)
                if ok then
                    ImGui.TextColored(0, 1, 0, 1, 'T')
                else
                    ImGui.TextColored(1, 0, 0, 1, 'F')
                end
            else
                ImGui.TextDisabled('-')
            end
            ImGui.TableSetColumnIndex(3)
            if ImGui.Button('[-]##condrem' .. i) then
                s.cond.expressions[i] = nil
                if i == s.cond.size and s.cond.size > 1 then
                    condArr[s.cond.size] = nil
                    s.cond.size = s.cond.size - 1
                    Config.set('KConditions', 'CondSize', tostring(s.cond.size))
                else
                    condArr[i] = 'null'
                end
                Config.set('KConditions', 'Cond', condArr)
                Config.save()
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('[+ Add]') then
        s.cond.size = (s.cond.size or 5) + 1
        condArr[s.cond.size] = 'null'
        Config.set('KConditions', 'Cond', condArr)
        Config.set('KConditions', 'CondSize', tostring(s.cond.size))
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

local function drawCures()
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
        condLabels[j + 1] = string.format('cond%03d', j)
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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx, cc = ImGui.Combo('##ccond' .. i, condNo + 1, condLabels)
            local newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)

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

local function drawBuffs()
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
        condLabels[j + 1] = string.format('cond%03d', j)
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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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

local function drawGoM()
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

-- ---------------------------------------------------------------------------
-- DPS panel helpers
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

local function drawAggro()
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
        condLabels[j + 1] = string.format('cond%03d', j)
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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##acond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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
-- DPS rotation panel
-- ---------------------------------------------------------------------------

local function drawDPS()
    local s = _state

    checkbox('DPS', s.combat.dpsOn, function(v)
        s.combat.dpsOn = v
        Config.set('DPS', 'DPSOn', v and '1' or '0')
        Config.save()
    end)
    ImGui.SameLine(120)
    checkbox('Debuff All', s.debuff.on ~= 0, function(v)
        s.debuff.on = v and 1 or 0
        Config.set('DPS', 'DebuffAllOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('DPS Skip %',   s.combat.dpsSkip,     0,  100, 'DPS', 'DPSSkip',     function(v) s.combat.dpsSkip     = v end)
    intInput('DPS Interval', s.combat.dpsInterval, 0, 3600, 'DPS', 'DPSInterval', function(v) s.combat.dpsInterval = v end)

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()
    ImGui.TextColored(0.7, 0.7, 0.7, 1.0, 'HP% 0 = use AssistAt.  HP% >= 101 = debuff slot.')
    ImGui.Spacing()

    local dpsRaw  = Config.get('DPS', 'DPS',     nil) or {}
    local dpsSize = tonumber(Config.get('DPS', 'DPSSize', '20')) or 20

    local function syncDpsArray()
        s.combat.dpsArray = {}
        s.debuff.slots    = {}
        s.debuff.count    = 0
        for _, slot in ipairs(Config.parseCondArray(dpsRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                local parts = {}
                for p in (slot.name .. '|'):gmatch('([^|]*)|') do parts[#parts+1] = p end
                local thresh = tonumber(parts[2]) or 0
                if thresh >= 101 then
                    s.debuff.slots[#s.debuff.slots + 1] = {
                        spell  = parts[1] or '',
                        tag1   = parts[3] or '',
                        tag2   = parts[4] or '',
                        condNo = slot.condNo,
                    }
                    s.debuff.count = s.debuff.count + 1
                else
                    s.combat.dpsArray[#s.combat.dpsArray + 1] = slot
                end
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('cond%03d', j)
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
            if tc then newThresh = tostring(math.max(0, math.min(200, newThreshNum))) end
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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##dcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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

local function drawBurn()
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

    if not s.combat.combatStart then ImGui.BeginDisabled() end
    if ImGui.Button('Burn Now') then mq.cmd('/burn') end
    if not s.combat.combatStart then ImGui.EndDisabled() end

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

    local function syncBurnArray()
        s.combat.burnArray = {}
        for _, slot in ipairs(Config.parseCondArray(burnRaw)) do
            if slot and slot.name and slot.name ~= '' and slot.name ~= 'null' then
                s.combat.burnArray[#s.combat.burnArray + 1] = slot
            end
        end
    end

    local condLabels = { '(none)' }
    for j = 1, (s.cond.size or 0) do
        condLabels[j + 1] = string.format('cond%03d', j)
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('burn_tbl', 6, tblFlags) then
        ImGui.TableSetupColumn('Spell',  ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('HP%',    ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed,    75)
        ImGui.TableSetupColumn('DAMod',  ImGuiTableColumnFlags.WidthFixed,    90)
        ImGui.TableSetupColumn('Cond',   ImGuiTableColumnFlags.WidthFixed,   160)
        ImGui.TableSetupColumn('',       ImGuiTableColumnFlags.WidthFixed,    32)
        ImGui.TableHeadersRow()

        for i = 1, burnSize do
            local raw     = burnRaw[i] or 'null'
            local isEmpty = (raw == 'null' or raw == '')
            local spell, thresh, target, damod, cond = splitDPS(isEmpty and '' or raw)
            local newSpell, newThresh, newTarget, newDamod, newCond = spell, thresh, target, damod, cond
            local sc, tc, tac, dc, cc = false, false, false, false, false

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newSpell, sc = ImGui.InputText('##bspell' .. i, spell, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local threshNum = tonumber(thresh) or 0
            local newThreshNum
            newThreshNum, tc = ImGui.InputInt('##bthresh' .. i, threshNum)
            if tc then newThresh = tostring(math.max(0, math.min(200, newThreshNum))) end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local targetIdx = 1
            for k, v in ipairs(ATGT_VALUES) do if v == target then targetIdx = k; break end end
            local newTargetIdx
            newTargetIdx, tac = ImGui.Combo('##btgt' .. i, targetIdx, ATGT_LABELS)
            if tac then newTarget = ATGT_VALUES[newTargetIdx] end
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            newDamod, dc = ImGui.InputText('##bdamod' .. i, damod, 0)
            ImGui.PopItemWidth()

            ImGui.TableNextColumn()
            ImGui.PushItemWidth(-1)
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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

            if sc or tc or tac or dc or cc then
                local spellVal = sc and newSpell or spell
                burnRaw[i] = spellVal ~= '' and joinDPS(
                    spellVal,
                    tc  and newThresh  or thresh,
                    tac and newTarget  or target,
                    dc  and newDamod   or damod,
                    cc  and newCond    or cond
                ) or 'null'
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

local function drawAE()
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
        condLabels[j + 1] = string.format('cond%03d', j)
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
            local condNo = tonumber(cond:match('cond(%d+)')) or 0
            local newCondIdx
            newCondIdx, cc = ImGui.Combo('##aecond' .. i, condNo + 1, condLabels)
            newCond = newCondIdx == 1 and '' or string.format('cond%03d', newCondIdx - 1)
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

-- ---------------------------------------------------------------------------
-- CC panel (Mez + Charm, class-gated)
-- ---------------------------------------------------------------------------

local function drawCC()
    local s = _state

    if ImGui.BeginTabBar('KACCTabs') then
        if s.session.iAmAMezClass and ImGui.BeginTabItem('Mez') then
            ImGui.Spacing()
            ImGui.PushItemWidth(200)
            local newMode, modeChanged = ImGui.Combo('Mode##mezmode', s.mez.on + 1, MEZ_MODE_LABELS)
            if modeChanged then
                s.mez.on = newMode - 1
                Config.set('Mez', 'MezOn', tostring(s.mez.on))
                Config.save()
            end
            ImGui.PopItemWidth()

            ImGui.Spacing()
            intInput('Mez Radius##mez', s.mez.radius,   1, 500, 'Mez', 'MezRadius',   function(v) s.mez.radius   = v end)
            intInput('Stop HP%##mez',   s.mez.stopHPs,  1, 100, 'Mez', 'MezStopHPs',  function(v) s.mez.stopHPs  = v end)
            intInput('Min Level##mez',  s.mez.minLevel, 1, 125, 'Mez', 'MezMinLevel', function(v) s.mez.minLevel = v end)
            intInput('Max Level##mez',  s.mez.maxLevel, 1, 125, 'Mez', 'MezMaxLevel', function(v) s.mez.maxLevel = v end)

            ImGui.Spacing()
            ImGui.Separator()
            ImGui.Text(string.format(
                'Haters on XTarget: %d total  /  %d within Mez Radius',
                s.mez.mobCount or 0, s.mez.mobAECount or 0))
            ImGui.Spacing()

            -- Spell + mob-count columns
            if ImGui.BeginTable('##mezspells', 3, 0) then
                ImGui.TableSetupColumn('Spell',     ImGuiTableColumnFlags.WidthStretch, 0)
                ImGui.TableSetupColumn('Min Mobs',  ImGuiTableColumnFlags.WidthFixed,  100)
                ImGui.TableSetupColumn('Label',     ImGuiTableColumnFlags.WidthFixed,  90)
                ImGui.TableHeadersRow()

                -- Mez Spell row
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.PushItemWidth(-1)
                local mezSpell, msc = ImGui.InputText('##mezspell', s.mez.spell, 0)
                ImGui.PopItemWidth()
                if msc and mezSpell ~= s.mez.spell then
                    s.mez.spell = mezSpell
                    Config.set('Mez', 'MezSpell', mezSpell .. '|' .. (s.mez.singleCount or 2))
                    Config.save()
                end
                ImGui.TableSetColumnIndex(1)
                ImGui.PushItemWidth(-1)
                local sc, scc = ImGui.InputInt('##singlecount', s.mez.singleCount or 2, 1, 1)
                ImGui.PopItemWidth()
                if scc then
                    sc = math.max(2, sc)
                    s.mez.singleCount = sc
                    Config.set('Mez', 'MezSpell', s.mez.spell .. '|' .. sc)
                    Config.save()
                end
                ImGui.TableSetColumnIndex(2)
                ImGui.Text('Mez Spell')

                -- AE Mez Spell row
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.PushItemWidth(-1)
                local aeMezSpell, asc = ImGui.InputText('##aespell', s.mez.aeSpell, 0)
                ImGui.PopItemWidth()
                if asc and aeMezSpell ~= s.mez.aeSpell then
                    s.mez.aeSpell = aeMezSpell
                    Config.set('Mez', 'MezAESpell', aeMezSpell .. '|' .. (s.mez.aeCount or 0))
                    Config.save()
                end
                ImGui.TableSetColumnIndex(1)
                ImGui.PushItemWidth(-1)
                local ac, acc = ImGui.InputInt('##aecount', s.mez.aeCount or 0, 1, 1)
                ImGui.PopItemWidth()
                if acc then
                    ac = math.max(0, ac)
                    s.mez.aeCount = ac
                    Config.set('Mez', 'MezAESpell', s.mez.aeSpell .. '|' .. ac)
                    Config.save()
                end
                ImGui.TableSetColumnIndex(2)
                ImGui.Text('AE Mez Spell')

                -- Debuff Spell row (no mob count)
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.PushItemWidth(-1)
                local debuffSpell, dsc = ImGui.InputText('##mezDebuff', s.mez.mezDebuffSpell, 0)
                ImGui.PopItemWidth()
                if dsc and debuffSpell ~= s.mez.mezDebuffSpell then
                    s.mez.mezDebuffSpell = debuffSpell
                    Config.set('Mez', 'MezDebuffSpell', debuffSpell)
                    Config.save()
                end
                ImGui.TableSetColumnIndex(1)
                ImGui.TextDisabled('—')
                ImGui.TableSetColumnIndex(2)
                ImGui.Text('Debuff Spell')

                ImGui.EndTable()
            end
            ImGui.EndTabItem()
        end

        if s.session.iAmACharmClass then
            if ImGui.BeginTabItem('Charm') then
                ImGui.Spacing()
                checkbox('Charm Keep', s.charm.keep, function(v)
                    s.charm.keep = v
                    Config.set('Charm', 'CharmKeep', v and '1' or '0')
                    Config.save()
                end)

                ImGui.Spacing()
                intInput('Charm Radius##charm', s.charm.radius,   1, 500, 'Charm', 'CharmRadius',   function(v) s.charm.radius   = v end)
                intInput('Min Level##charm',    s.charm.minLevel, 1, 125, 'Charm', 'CharmMinLevel', function(v) s.charm.minLevel = v end)
                intInput('Max Level##charm',    s.charm.maxLevel, 0, 125, 'Charm', 'CharmMaxLevel', function(v) s.charm.maxLevel = v end)

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.PushItemWidth(220)
                local charmSpell, csc = ImGui.InputText('Charm Spell##charmspell', s.charm.spell, 0)
                if csc and charmSpell ~= s.charm.spell then
                    s.charm.spell = charmSpell
                    Config.set('Charm', 'CharmSpell', charmSpell)
                    Config.save()
                end
                ImGui.PopItemWidth()
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    end
end

-- ---------------------------------------------------------------------------
-- AFK Tools panel
-- ---------------------------------------------------------------------------

local function drawAfkTools()
    local s = _state

    ImGui.PushItemWidth(200)
    local newMode, modeChanged = ImGui.Combo('Mode##afkmode', s.afk.on + 1, AFK_MODE_LABELS)
    if modeChanged then
        s.afk.on = newMode - 1
        Config.set('AFKTools', 'AFKToolsOn', tostring(s.afk.on))
        Config.save()
        if (s.afk.on == 1 or s.afk.on == 2) and mq.TLO.Plugin('MQ2Posse').IsLoaded() then
            mq.cmdf('/posse radius %d', s.afk.pcRadius)
        end
    end
    ImGui.PopItemWidth()

    -- GM Action: only when mode includes GM detection
    if s.afk.on == 1 or s.afk.on == 3 then
        ImGui.Spacing()
        ImGui.PushItemWidth(200)
        local newAction, actionChanged = ImGui.Combo('GM Action##afkgmaction', math.max(1, s.afk.gmAction), AFK_ACTION_LABELS)
        if actionChanged then
            s.afk.gmAction = newAction
            Config.set('AFKTools', 'AFKGMAction', tostring(newAction))
            Config.save()
        end
        ImGui.PopItemWidth()
    end

    -- PC Radius: only when mode includes stranger detection
    if s.afk.on == 1 or s.afk.on == 2 then
        ImGui.Spacing()
        local newRadius = ImGui.InputInt('PC Radius##afkpcradius', s.afk.pcRadius)
        if newRadius ~= s.afk.pcRadius then
            newRadius = math.max(1, math.min(5000, newRadius))
            s.afk.pcRadius = newRadius
            Config.set('AFKTools', 'AFKPCRadius', tostring(newRadius))
            Config.save()
            if mq.TLO.Plugin('MQ2Posse').IsLoaded() then
                mq.cmdf('/posse radius %d', newRadius)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Draw callback — registered with mq.imgui.init
-- ---------------------------------------------------------------------------

local function draw()
    if not _open then return end
    local miniMode = _state.ui.miniMode
    if _pendingW > 0 then
        ImGui.SetNextWindowSize(_pendingW, _pendingH, 1)  -- 1 = ImGuiCond_Always
        _pendingW, _pendingH = 0, 0
    end
    local winFlags = miniMode and ImGuiWindowFlags.NoResize or 0
    local shouldDraw
    _open, shouldDraw = ImGui.Begin('KissAssist Lua', _open, winFlags)
    if not _open then _state.terminate = true end
    if shouldDraw then
        -- mini-mode toggle button, right-aligned on the first status row
        local btnLabel = miniMode and '[+]' or '[-]'
        local savedY = ImGui.GetCursorPosY()
        ImGui.SetCursorPosX(ImGui.GetWindowWidth() - 32)
        if ImGui.SmallButton(btnLabel) then
            if not miniMode then
                -- entering mini: save current size, schedule shrink to fixed mini dimensions
                _savedFullW, _savedFullH = ImGui.GetWindowSize()
                _pendingW, _pendingH = MINI_W, MINI_H
            else
                -- exiting mini: schedule restore to saved (or default) size
                _pendingW = _savedFullW > 0 and _savedFullW or 640
                _pendingH = _savedFullH > 0 and _savedFullH or 500
            end
            _state.ui.miniMode = not miniMode
            Config.set('UI', 'MiniMode', _state.ui.miniMode and '1' or '0')
            Config.save()
        end
        ImGui.SetCursorPosY(savedY)

        drawStatus()
        if miniMode then
            ImGui.End()
            return
        end
        ImGui.Separator()
        if ImGui.BeginTabBar('KATabs') then
            if ImGui.BeginTabItem('Combat') then
                if ImGui.BeginTabBar('KACombatTabs') then
                    if ImGui.BeginTabItem('Melee') then
                        drawMelee()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('DPS') then
                        drawDPS()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Burn') then
                        drawBurn()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Aggro') then
                        drawAggro()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('AE') then
                        drawAE()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Healing') then
                if ImGui.BeginTabBar('KAHealingTabs') then
                    if ImGui.BeginTabItem('Heals') then
                        drawHealThresholds()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Cures') then
                        drawCures()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Spells') then
                if ImGui.BeginTabBar('KASpellsTabs') then
                    if ImGui.BeginTabItem('Spells') then
                        drawSpellSlots()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Buffs') then
                        drawBuffs()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('GoM') then
                        drawGoM()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Support') then
                if ImGui.BeginTabBar('KASupportTabs') then
                    if ImGui.BeginTabItem('Pet') then
                        drawPet()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Merc') then
                        drawMerc()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Pull') then
                drawPull()
                ImGui.EndTabItem()
            end
            if _state.session.iAmAMezClass or _state.session.iAmACharmClass then
                if ImGui.BeginTabItem('CC') then
                    drawCC()
                    ImGui.EndTabItem()
                end
            end
            if ImGui.BeginTabItem('Config') then
                if ImGui.BeginTabBar('KAConfigTabs') then
                    if ImGui.BeginTabItem('Settings') then
                        drawControls()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('Conditions') then
                        drawConditions()
                        ImGui.EndTabItem()
                    end
                    if ImGui.BeginTabItem('AFK Tools') then
                        drawAfkTools()
                        ImGui.EndTabItem()
                    end
                    ImGui.EndTabBar()
                end
                ImGui.EndTabItem()
            end
            if _state.session.iAmABard then
                if ImGui.BeginTabItem('Bard') then
                    drawBard()
                    ImGui.EndTabItem()
                end
            end
            ImGui.EndTabBar()
        end
    end
    ImGui.End()
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function UI.init(state, cond)
    _state = state
    _cond  = cond
    _state.ui.miniMode = Config.get('UI', 'MiniMode', '0') == '1'
    mq.imgui.init('KissAssist Lua', draw)
    mq.bind('/kaui', function(arg)
        if arg == 'mini' then
            _state.ui.miniMode = not _state.ui.miniMode
            Config.set('UI', 'MiniMode', _state.ui.miniMode and '1' or '0')
            Config.save()
        else
            _open = not _open
        end
    end)
end

return UI
