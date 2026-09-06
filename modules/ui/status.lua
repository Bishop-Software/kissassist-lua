-- ui/status.lua — top status readout and the camp/chase/burn button row.
-- Shown in both full and mini UI modes.

local mq = require('mq')

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
    elseif s.combat.combatStart then
        combatLabel, cr, cg, cb = 'FIGHTING',  1.0, 0.4, 0.4
    elseif s.pull.pulling then
        combatLabel, cr, cg, cb = 'PULLING',   1.0, 0.9, 0.1
    elseif s.movement.returnToCamp and isReturningToCamp(s) then
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

function Status.drawCampButtons()
    local bw = math.floor((ImGui.GetContentRegionAvail() - 16) / 5)
    if ImGui.Button('Camp Here', bw, 0) then mq.cmd('/makecamphere') end
    ImGui.SameLine()
    if ImGui.Button('Camp Off',  bw, 0) then mq.cmd('/campoff')      end
    ImGui.SameLine()
    if ImGui.Button('Chase Me',  bw, 0) then mq.cmd('/chaseme')      end
    ImGui.SameLine()
    if ImGui.Button('Stay Here', bw, 0) then mq.cmd('/stayhere')     end
    ImGui.SameLine()
    if not _state.combat.combatStart then ImGui.BeginDisabled() end
    if ImGui.Button('Burn Now',  -1, 0) then mq.cmd('/burn')         end
    if not _state.combat.combatStart then ImGui.EndDisabled() end
end

function Status.init(state)
    _state = state
end

return Status
