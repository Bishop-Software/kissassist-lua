-- ui.lua — ImGui status and control panel.
-- Registered with mq.imgui.init; drawn each frame by the MQ2Lua runtime.
-- Reads State.* for display; writes go through existing bind toggle functions
-- so UI and /ka* chat commands stay in sync.

local mq = require('mq')

local AF_LABELS = { [0]='OFF', [1]='RANGED', [2]='PAUSED' }
local GLT_VALUES  = { '<', '<<', '>' }
local GLT_LABELS  = { '< gain', '<< sec', '> lose' }
local ATGT_VALUES = { '', 'me', 'ma', 'pet', 'inc' }
local ATGT_LABELS = { 'current', 'me', 'ma', 'pet', 'inc' }
local AF_COLORS = {
    [0] = {0.6, 0.6, 0.6},
    [1] = {0.4, 1.0, 0.4},
    [2] = {1.0, 0.9, 0.1},
}

local Config = require('modules.config')

local UI = {}
local _state
local _open = true
local COL    = 130  -- column width for checkbox SameLine and button widths

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

local function drawStatus()
    local s = _state

    -- Combat state label + color
    local combatLabel, cr, cg, cb
    if s.session.iAmDead then
        combatLabel, cr, cg, cb = 'DEAD',     1.0, 0.2, 0.2
    elseif s.combat.combatStart then
        combatLabel, cr, cg, cb = 'FIGHTING', 1.0, 0.4, 0.4
    elseif s.pull.pulling then
        combatLabel, cr, cg, cb = 'PULLING',  1.0, 0.9, 0.1
    else
        combatLabel, cr, cg, cb = 'IDLE',     0.4, 1.0, 0.4
    end

    -- Row 1: role / MA
    ImGui.Text(string.format('Role: %-14s', s.session.role or ''))
    ImGui.SameLine()
    ImGui.Text(string.format('MA: %s', s.session.mainAssist or ''))

    -- Row 2: state / burn / autofire
    ImGui.Text('State: ')
    ImGui.SameLine()
    ImGui.TextColored(cr, cg, cb, 1.0, combatLabel)
    ImGui.SameLine()
    ImGui.Text(string.format('   Burn: %s', s.combat.burnOn and 'ON' or 'OFF'))
    ImGui.SameLine()
    local af = s.combat.autoFireOn or 0
    local afc = AF_COLORS[af]
    ImGui.Text('  AutoFire: ')
    ImGui.SameLine()
    ImGui.TextColored(afc[1], afc[2], afc[3], 1.0, AF_LABELS[af])

    -- Row 3: target / mob count
    local targetName = ''
    local aggroID = tonumber(s.combat.aggroTargetID) or 0
    if aggroID > 0 then
        targetName = mq.TLO.Spawn(aggroID).CleanName() or ''
    end
    ImGui.Text(string.format('Target: %-20s  Mobs: %d', targetName, s.combat.mobCount or 0))

    -- Row 4: camp location / radius
    local mv = s.movement
    local isPuller = ({ puller=true, pullertank=true, pullerpettank=true,
                        hunter=true, hunterpettank=true })[s.session.role or '']
    if isPuller and (mv.campX or 0) == 0 and (mv.campY or 0) == 0 then
        ImGui.TextColored(1.0, 0.2, 0.2, 1.0, 'No Camp Set — run /makecamphere')
    else
        ImGui.Text(string.format('Camp: (%.0f, %.0f, %.0f)  Radius: %d',
            mv.campY or 0, mv.campX or 0, mv.campZ or 0, mv.campRadius or 0))
    end
end

-- ---------------------------------------------------------------------------
-- Toggle Controls panel
-- ---------------------------------------------------------------------------

local function checkbox(label, value, onChange)
    local newVal = ImGui.Checkbox(label, value)
    if newVal ~= value then onChange(newVal) end
end

local function drawControls()
    local s = _state

    -- Row 1
    checkbox('Cures', s.heal.curesOn ~= 0, function(v)
        s.heal.curesOn = v and 1 or 0
    end)

    -- Row 2
    checkbox('Mez', s.mez.on ~= 0, function(v)
        s.mez.on = v and 1 or 0
    end)

    -- Row 3
    checkbox('Burn', s.combat.burnOn, function(_)
        mq.cmd('/burn')
    end)

    -- Row 4
    checkbox('Loot', s.loot.on ~= 0, function(v)
        mq.cmd(v and '/kalooton' or '/kalootoff')
    end)
    ImGui.SameLine(120)
    checkbox('AFK', s.afk.on ~= 0, function(v)
        s.afk.on = v and 1 or 0
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
end

-- ---------------------------------------------------------------------------
-- Live Config Editing panel
-- ---------------------------------------------------------------------------

local function intInput(label, value, min, max, configSection, configKey, stateSet)
    local newVal = ImGui.InputInt(label, value)
    if newVal ~= value then
        newVal = math.max(min, math.min(max, newVal))
        stateSet(newVal)
        Config.set(configSection, configKey, tostring(newVal))
        Config.save()
    end
end

local function drawConfig()
    local s = _state

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

    checkbox('AutoFire', (s.combat.autoFireOn or 0) ~= 0, function(_)
        mq.cmd('/autofireon')
    end)
    ImGui.SameLine(120)
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
    local condPos = raw:find('|cond%d')
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
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('heals_tbl', 5, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Pct',   ImGuiTableColumnFlags.WidthFixed,    70)
        ImGui.TableSetupColumn('Tag',   ImGuiTableColumnFlags.WidthFixed,   100)
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
            newCondIdx, cc = ImGui.Combo('##hcond' .. i, condNo, condLabels)
            newCond = newCondIdx == 0 and '' or string.format('cond%03d', newCondIdx)
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

local function drawSpellSlots()
    local gemSlots = _state.cast.gemSlots or 8
    ImGui.PushItemWidth(220)
    for i = 1, gemSlots do
        local current = Config.get('Spells', 'Gem' .. i, '')
        local newVal, changed = ImGui.InputText('Gem ' .. i .. '##gem' .. i, current, 0)
        if changed and newVal ~= current then
            Config.set('Spells', 'Gem' .. i, newVal)
            Config.save()
        end
    end
    ImGui.PopItemWidth()

    ImGui.Spacing()
    if ImGui.Button('Write Current Gems') then
        Config.writeSpells(_state)
    end
end

-- ---------------------------------------------------------------------------
-- Pet panel
-- ---------------------------------------------------------------------------

local function drawPet()
    local s = _state

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

local function drawBard()
    ---@diagnostic disable-next-line: undefined-field
    local Medley   = mq.TLO.Medley
    local bard     = _state.bard
    local active    = Medley.Active() or false
    local activeSet = Medley.Medley() or '—'

    ImGui.Text(string.format('Active set: %s  (%s)', activeSet, active and 'playing' or 'stopped'))
    ImGui.Separator()

    -- Set switch buttons
    if ImGui.Button(bard.meleeMedley) then mq.cmdf('/medley %s', bard.meleeMedley) end
    ImGui.SameLine()
    if ImGui.Button(bard.burnMedley)  then mq.cmdf('/medley %s', bard.burnMedley)  end
    ImGui.SameLine()
    if ImGui.Button(bard.oorMedley)   then mq.cmdf('/medley %s', bard.oorMedley)   end

    -- Pause / Resume
    ImGui.Spacing()
    if ImGui.Button('Pause')  then mq.cmd('/medley pause')  end
    ImGui.SameLine()
    if ImGui.Button('Resume') then mq.cmd('/medley resume') end
    ImGui.SameLine()
    if ImGui.Button('Stop')   then mq.cmd('/medley stop')   end
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

    ImGui.PushItemWidth(300)
    for i = 1, (s.cond.size or 5) do
        local current = s.cond.expressions[i] or ''
        local newVal, changed = ImGui.InputText(string.format('Cond %03d##cond%d', i, i), current, 0)
        if changed and newVal ~= current then
            s.cond.expressions[i] = newVal ~= '' and newVal or nil
            condArr[i] = newVal ~= '' and newVal or 'null'
            Config.set('KConditions', 'Cond', condArr)
            Config.save()
        end
        ImGui.SameLine()
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
    ImGui.PopItemWidth()

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
-- Buffs panel
-- ---------------------------------------------------------------------------

local function splitBuff(raw)
    -- SpellName[|TargetTag][|condNNN]  →  spell, tag, cond
    local spell, tag, cond = raw, '', ''
    local condPos = raw:find('|cond%d')
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
    ImGui.SameLine(120)
    checkbox('Rebuff On', s.buffs.rebuffOn, function(v)
        s.buffs.rebuffOn = v
        Config.set('Buffs', 'RebuffOn', v and '1' or '0')
        Config.save()
    end)

    ImGui.Spacing()
    intInput('Check Timer', s.buffs.checkBuffsTimer, 1, 3600, 'Buffs', 'CheckBuffsTimer',
        function(v) s.buffs.checkBuffsTimer = v end)

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
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
    end

    local tblFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.SizingFixedFit)
    if ImGui.BeginTable('buffs_tbl', 4, tblFlags) then
        ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 0)
        ImGui.TableSetupColumn('Tag',   ImGuiTableColumnFlags.WidthFixed,   110)
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
            newCondIdx, cc = ImGui.Combo('##bcond' .. i, condNo, condLabels)
            newCond = newCondIdx == 0 and '' or string.format('cond%03d', newCondIdx)
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
-- Aggro panel
-- ---------------------------------------------------------------------------

local function splitAggro(raw)
    -- SpellName[|pct[|glt[|target]]][|condNNN]  →  spell, pct, glt, target, cond
    local spell, pct, glt, target, cond = '', '0', '<', '', ''
    local condPos = raw:find('|cond%d')
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
    local condPos = raw:find('|cond%d')
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

    ImGui.SameLine(120)
    ImGui.Text('Aggro: ')
    ImGui.SameLine()
    if (mq.TLO.Me.Level() or 0) < 20 then
        ImGui.TextColored(0.6, 0.6, 0.6, 1.0, 'N/A (< lvl 20)')
    else
        local pctAggro = mq.TLO.Me.PctAggro() or 0
        local ar, ag, ab
        if pctAggro >= 100 then
            ar, ag, ab = 0.2, 1.0, 0.2
        elseif pctAggro >= 75 then
            ar, ag, ab = 1.0, 0.9, 0.1
        else
            ar, ag, ab = 1.0, 0.3, 0.3
        end
        ImGui.TextColored(ar, ag, ab, 1.0, pctAggro .. '%')
    end

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
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
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
            newCondIdx, cc = ImGui.Combo('##acond' .. i, condNo, condLabels)
            newCond = newCondIdx == 0 and '' or string.format('cond%03d', newCondIdx)
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
        local expr = (s.cond.expressions and s.cond.expressions[j]) or ''
        condLabels[j + 1] = string.format('cond%03d: %s', j, expr ~= '' and expr or '(empty)')
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
            newCondIdx, cc = ImGui.Combo('##dcond' .. i, condNo, condLabels)
            newCond = newCondIdx == 0 and '' or string.format('cond%03d', newCondIdx)
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
-- Draw callback — registered with mq.imgui.init
-- ---------------------------------------------------------------------------

local function draw()
    if not _open then return end
    if ImGui.Begin('KissAssist') then
        drawStatus()
        ImGui.Separator()
        if ImGui.BeginTabBar('KATabs') then
            if ImGui.BeginTabItem('Controls') then
                drawControls()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Melee') then
                drawMelee()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('DPS') then
                drawDPS()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Aggro') then
                drawAggro()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Pull') then
                drawPull()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Config') then
                drawConfig()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Heals') then
                drawHealThresholds()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Spells') then
                drawSpellSlots()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Buffs') then
                drawBuffs()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Pet') then
                drawPet()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Merc') then
                drawMerc()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Conditions') then
                drawConditions()
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

function UI.init(state)
    _state = state
    mq.imgui.init('KissAssist', draw)
    mq.bind('/kaui', function() _open = not _open end)
end

return UI
