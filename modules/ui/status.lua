-- ui/status.lua — top status readout and the camp/chase/burn button row.
-- Shown in both full and mini UI modes.

local mq      = require('mq')
local Control = require('modules.control')

local AF_LABELS = { [0]='OFF', [1]='RANGED', [2]='PAUSED' }
local AF_COLORS = {
    [0] = {0.6, 0.6, 0.6},
    [1] = {0.4, 1.0, 0.4},
    [2] = {1.0, 0.9, 0.1},
}

local Status = {}
local _state

-- True only while actually away from camp (not merely because ReturnToCamp is
-- enabled). Mirrors Movement.doWeMove gating: same zone, camp set, and beyond
-- camp radius. Movement settles within campRadius, so inside it we're "home".
local function isReturningToCamp(s)
    local mv = s.movement
    if mv.campX == 0 and mv.campY == 0 then return false end
    if mq.TLO.Zone.ID() ~= mv.campZone then return false end
    local dy = (mq.TLO.Me.Y() or 0) - mv.campY
    local dx = (mq.TLO.Me.X() or 0) - mv.campX
    return math.sqrt(dy * dy + dx * dx) > (mv.campRadius or 50)
end

function Status.drawStatus()
    local s = _state
    local C2, C3 = 160, 320  -- fixed column offsets (px from window left edge)

    -- Combat state label + color
    local combatLabel, cr, cg, cb
    if s.session.iAmDead then
        combatLabel, cr, cg, cb = 'DEAD',      1.0, 0.2, 0.2
    elseif s.session.paused then
        combatLabel, cr, cg, cb = 'PAUSED',    1.0, 0.3, 0.8
    elseif s.dps.paused then
        combatLabel, cr, cg, cb = 'BACKED OFF', 1.0, 0.6, 0.2
    elseif s.combat.combatStart then
        combatLabel, cr, cg, cb = 'FIGHTING',  1.0, 0.4, 0.4
    elseif s.pull.pulling then
        combatLabel, cr, cg, cb = 'PULLING',   1.0, 0.9, 0.1
    elseif s.movement.returnToCamp and isReturningToCamp(s) then
        combatLabel, cr, cg, cb = 'RETURNING', 1.0, 0.7, 0.2
    elseif s.heal.medding then
        combatLabel, cr, cg, cb = 'MEDDING',   0.4, 0.8, 1.0
    elseif s.heal.petMedding then
        combatLabel, cr, cg, cb = 'HEALING PET', 0.4, 0.8, 1.0
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

-- Pure. How many buttons go on a row and how wide each is, so that every
-- label fits: as many per row as fit at the widest label's width, then the
-- rows balanced (7 buttons that fit 5 a row go 4 + 3, not 5 + 2).
function Status.buttonLayout(avail, need, spacing, n)
    if n <= 0 then return 0, 0 end
    local perRow = math.floor((avail + spacing) / (need + spacing))
    perRow = math.max(1, math.min(n, perRow))
    local rows = math.ceil(n / perRow)
    perRow = math.ceil(n / rows)
    local bw = math.floor((avail - spacing * (perRow - 1)) / perRow)
    return perRow, bw
end

-- ImGui style values, with defaults if the binding doesn't expose them.
local function styleX(field, default)
    local ok, v = pcall(function() return ImGui.GetStyle()[field].x end)
    return (ok and type(v) == 'number') and v or default
end

local function textWidth(text)
    local a = ImGui.CalcTextSize(text)
    if type(a) == 'number' then return a end
    return (a and a.x) or (#text * 7)
end

-- The button row under the status block, in full and mini mode. Wraps onto a
-- second row when the window is too narrow for every label.
function Status.drawCampButtons()
    local s = _state
    local inFight = s.combat.combatStart
    local paused  = s.dps.paused
    local kaPaused = s.session.paused
    local mv       = s.movement
    local camping  = mv.returnToCamp
    local hasCamp  = (mv.campX or 0) ~= 0 or (mv.campY or 0) ~= 0
    -- [2] is a function. The movement buttons call Control.setMode; the rest
    -- queue a /kactl verb with Control.defer, which runs it on the main loop
    -- (a verb may wait, and that can't happen inside the ImGui frame) (#360).
    local buttons = {
        -- Group camp toggle: camp here for everyone, or break camp for everyone.
        { camping and 'Break Camp##grpcamp' or 'Camp Here##grpcamp',
          camping and function() Control.setMode('manual', { clear = true, group = true }) end
              or function() Control.setMode('camp', { here = true, group = true }) end,
          tip = camping and 'Group: break camp for every kissassist-lua box in the group (/kactl mode manual clear group)'
              or 'Group: every kissassist-lua box in the group camps at this spot (/kactl mode camp here group)' },
        -- This toon's camp toggle: off keeps the spot, on goes back to it.
        { camping and 'Camp Off##mycamp' or 'Camp On##mycamp',
          camping and function() Control.setMode('manual') end
              or function() Control.setMode('camp', { resume = true }) end,
          disabled = not camping and not hasCamp,
          tip = camping and 'This toon only: stop returning to camp; the camp is kept (/kactl mode manual)'
              or string.format('This toon only: go back to the camp at %.0f, %.0f (/kactl mode camp resume)',
                  mv.campY or 0, mv.campX or 0) },
        { 'Chase Me', function()
              Control.setMode('chase', { who = mq.TLO.Me.CleanName() or '', others = true })
          end, tip = 'The group\'s kissassist-lua boxes chase this toon (/kactl mode chase me others)' },
        { 'Stay Here', function() Control.setMode('manual', { others = true }) end,
          tip = 'The group\'s kissassist-lua boxes stop chasing and returning to camp (/kactl mode manual others)' },
        { 'Burn Now', function() Control.defer('burn') end, disabled = not inFight,
          tip = 'Burn the fight target now; turns Burn on for this session (/kactl burn)' },
        -- A buff pass now (skipped in combat, so disabled then).
        { 'Buff Now', function() Control.defer('buff', { 'now' }) end, disabled = inFight,
          tip = 'Run a buff pass now (/kactl buff now); not during a fight' },
        -- Back off (Bind_BackOff): highlighted while backed off.
        { paused and 'Resume##backoff' or 'Back Off##backoff',
          function() Control.defer('backoff', { paused and 'off' or 'on' }) end,
          color = paused and { 0.8, 0.45, 0.1, 1.0 } or nil,
          tip = paused and 'Backed off: click to resume fighting (/kactl backoff off)'
              or 'Stop fighting: attack, MQ2Melee and stick off, combat reset (/kactl backoff on)' },
        -- Soft pause (#353): highlighted while paused.
        { kaPaused and 'Unpause##kapause' or 'Pause##kapause',
          function() Control.defer('pause', { kaPaused and 'off' or 'on' }) end,
          color = kaPaused and { 0.7, 0.15, 0.5, 1.0 } or nil,
          tip = kaPaused and 'Paused: click to resume all automation (/kactl pause off)'
              or 'Pause all automation; commands and this window keep working (/kactl pause on)' },
    }

    local spacing = styleX('ItemSpacing', 8)
    local pad     = styleX('FramePadding', 4) * 2
    local need = 0
    for _, b in ipairs(buttons) do
        need = math.max(need, textWidth((b[1]:gsub('##.*$', ''))) + pad)
    end
    local perRow, bw = Status.buttonLayout(ImGui.GetContentRegionAvail(), need, spacing, #buttons)

    for i, b in ipairs(buttons) do
        if (i - 1) % perRow ~= 0 then ImGui.SameLine() end
        if b.disabled then ImGui.BeginDisabled() end
        if b.color then ImGui.PushStyleColor(ImGuiCol.Button, b.color[1], b.color[2], b.color[3], b.color[4]) end
        if ImGui.Button(b[1], bw, 0) then
            b[2]()
        end
        if b.color then ImGui.PopStyleColor() end
        if b.disabled then ImGui.EndDisabled() end
        if b.tip and ImGui.IsItemHovered() then ImGui.SetTooltip(b.tip) end
    end
end

function Status.init(state)
    _state = state
end

return Status
