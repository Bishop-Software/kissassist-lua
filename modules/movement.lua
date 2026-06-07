local mq     = require('mq')
local Config = require('modules.config')

local Movement = {}
local _state, _utils

local function dist2D(y1, x1, y2, x2)
    return math.sqrt((y1 - y2)^2 + (x1 - x2)^2)
end

local function isPullerRole(role)
    return role == 'puller' or role == 'pullertank' or role == 'pullerpettank'
end

local function isPullerOrHunterRole(role)
    return role == 'puller'  or role == 'pullertank'     or role == 'pullerpettank'
        or role == 'hunter' or role == 'hunterpettank'
end

function Movement.init(state, utils)
    _state = state
    _utils = utils

    -- [General] camp and movement settings
    _state.movement.returnToCamp     = Config.get('General', 'ReturnToCamp',     '0') == '1'
    _state.movement.campRadius       = tonumber(Config.get('General', 'CampRadius',       '50')) or 50
    _state.movement.campRadiusExceed = tonumber(Config.get('General', 'CampRadiusExceed', '0'))  or 0
    _state.session.chaseAssist       = Config.get('General', 'ChaseAssist',      '0') == '1'
    _state.movement.whoToChase       = Config.get('General', 'WhoToChase',       '') or ''
    _state.movement.dontMoveMe       = Config.get('General', 'DontMoveMe',       '0') == '1'
    _state.movement.stayPut          = Config.get('General', 'StayPut',          '0') == '1'
    _state.movement.stickDist        = tonumber(Config.get('General', 'StickDist',        '13')) or 13
    _state.movement.stickDistUW      = tonumber(Config.get('General', 'StickDistUW',      '10')) or 10
    _state.movement.dStickHow        = Config.get('Melee',   'StickHow',         '0') or '0'
    _state.movement.navPathHelper    = Config.get('General', 'NavPathHelper',    '1') ~= '0'
    _state.movement.locDelayCheckUW  = Config.get('General', 'LocDelayCheckUW',  '0') == '1'
    _state.movement.faceMobOn        = tonumber(Config.get('Melee', 'FaceMobOn', '0')) or 0
    _state.movement.scatterOn        = Config.get('General', 'ScatterOn',        '0') == '1'
    _state.movement.scatterDistance  = tonumber(Config.get('General', 'ScatterDistance',  '20')) or 20

    -- [Pull] movement-related pull settings
    _state.pull.moveUse        = Config.get('Pull', 'PullMoveUse', 'los') or 'los'
    _state.pull.max            = tonumber(Config.get('Pull', 'MaxRadius', '0')) or 0
    _state.pull.waypointZRange = tonumber(Config.get('Pull', 'MaxZRange', '0')) or 0

    -- One-time MQ2MoveUtils global settings (mac:16390-16398).
    -- usefleeing on: stick pursues mobs that run away.
    -- feign on: stick breaks when feign death is detected.
    mq.cmd('/stick set autosave off')
    mq.cmd('/stick set verbflags 0')
    mq.cmd('/stick set breakonkb on')
    mq.cmd('/stick set breakonmouse off')
    mq.cmdf('/stick set breakdist %d', _state.movement.campRadiusExceed)
    mq.cmd('/stick set breakonwarp on')
    mq.cmd('/stick set usefleeing on')
    mq.cmd('/stick set delaystrafe on')
    mq.cmd('/stick set feign on')
end

-- Port of DoWeMove (kissassist.mac:3342-3663).
-- forceFlag=1: move back to camp even when stayPut/ReturnToCamp is off.
function Movement.doWeMove(forceFlag, sentFrom)
    local mv   = _state.movement
    local role = _state.session.role

    if not mv.returnToCamp and (forceFlag or 0) == 0 then return end

    mq.doevents()

    local dist = dist2D(mv.campY, mv.campX, mq.TLO.Me.Y(), mq.TLO.Me.X())

    -- Leash: if dragged far beyond CampRadiusExceed (e.g. CoH), disable ReturnToCamp
    if mv.campRadiusExceed > 0 and dist > mv.campRadiusExceed
       and not (role == 'hunter' or role == 'hunterpettank')
       and mv.returnToCamp and mq.TLO.Zone.ID() == mv.campZone then
        mv.returnToCamp = false
        printf('\ayLeashing exceeded %d, turning off ReturnToCamp.', mv.campRadiusExceed)
        return
    end

    if dist <= 12 or mq.TLO.Zone.ID() ~= mv.campZone then return end

    -- Stand up from feign when safe to do so
    if mq.TLO.Me.Feigning() then
        if _state.timers.aggroOff > os.clock() then
            while mq.TLO.Me.Feigning() do mq.doevents(); mq.delay(50) end
        else
            mq.doevents(); mq.delay(100)
            if mq.TLO.Me.Feigning() then mq.cmd('/stand') end
        end
    end

    -- Puller already in camp radius: pull from here, no movement needed
    if isPullerRole(role) and dist <= mv.campRadius
       and (forceFlag or 0) == 0 and not _state.heal.medding then
        return
    end

    local timeout = os.clock() + 30

    -- Puller/hunter roles: use configured nav mode for longer returns
    if isPullerOrHunterRole(role) and dist > 15 then

        if _state.pull.moveUse == 'nav' and dist > mv.campRadius then
            -- MQ2Nav path back to camp (mac:3395-3490)
            local stuckCount = 0
            local x1, y1 = math.floor(mq.TLO.Me.X()), math.floor(mq.TLO.Me.Y())
            while true do
                mq.doevents()
                if _state.session.iAmDead or mq.TLO.Me.Hovering() then
                    if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
                    return
                end
                if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                mq.cmdf('/squelch /nav locxyz %f %f %f', mv.campX, mv.campY, mv.campZ)

                while true do
                    mq.delay(50)
                    if mq.TLO.Me.Hovering() then break end
                    local cx = math.floor(mq.TLO.Me.X())
                    local cy = math.floor(mq.TLO.Me.Y())
                    if mq.TLO.Me.Stunned() then
                        while mq.TLO.Me.Stunned() do mq.delay(20) end
                        break
                    elseif not mq.TLO.Me.Feigning() then
                        if cx == x1 and cy == y1 then
                            stuckCount = stuckCount + 1
                            if stuckCount >= 3 then
                                if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
                                Movement.stuck()
                                stuckCount = 0
                                break
                            end
                        else
                            stuckCount = 0
                        end
                        x1, y1 = cx, cy
                    end
                    -- CheckOnReturn: signal pull module when back within pull range (Step 7.8)
                    local d = dist2D(mv.campY, mv.campX, mq.TLO.Me.Y(), mq.TLO.Me.X())
                    if not mq.TLO.Navigation.Active() or d <= mv.campRadius then break end
                    if os.clock() > timeout then break end
                end

                local d2 = dist2D(mv.campY, mv.campX, mq.TLO.Me.Y(), mq.TLO.Me.X())
                if d2 < 16 or not mq.TLO.Navigation.Active() or os.clock() > timeout then break end
            end

        elseif _state.pull.moveUse == 'advpath' and _state.pull.pathWpCount > 0 then
            -- MQ2AdvPath: replay pull path in reverse (mac:3492-3520)
            mq.cmdf('/squelch /play %s reverse nodoor smart', _state.session.pullPath)
            while true do
                mq.doevents()
                if _state.session.iAmDead or mq.TLO.Me.Hovering() then
                    if mq.TLO.AdvPath.State() then mq.cmd('/squelch /play off') end
                    return
                end
                mq.delay(50)
                local wpCurrent = mq.TLO.AdvPath.NextWaypoint() or 0
                if mq.TLO.AdvPath.State() == 0 or wpCurrent < 2 then break end
                if os.clock() > timeout then break end
            end
            if mq.TLO.AdvPath.State() then mq.cmd('/play off') end
        end

    elseif _state.pull.moveUse == 'nav' then
        -- Non-puller MQ2Nav return to camp (mac:3521-3546)
        mq.doevents()
        if _state.session.iAmDead or mq.TLO.Me.Hovering() then
            if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
            return
        end
        if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then mq.cmd('/stand') end
        mq.cmdf('/squelch /nav locxyz %f %f %f', mv.campX, mv.campY, mv.campZ)
        while true do
            if _state.session.iAmDead or mq.TLO.Me.Hovering() then
                if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
                return
            end
            if not mq.TLO.Navigation.Active() then break end
            if dist2D(mv.campY, mv.campX, mq.TLO.Me.Y(), mq.TLO.Me.X()) <= mv.campRadius then break end
            if os.clock() > timeout then break end
            mq.delay(50)
        end
    end

    -- MQ2MoveUtils moveto: final approach for all roles and nav modes (mac:3547-3658)
    if not mq.TLO.Me.FeetWet() then mq.cmd('/look 0') end
    mq.cmd('/moveto dist 10')

    -- Scatter: randomize return point so toons don't always stack on the same spot
    local campYRandom, campXRandom
    if mv.scatterOn then
        local sd = math.random(5, 12)
        campYRandom = mv.campY + (math.random(2) == 1 and -sd or sd)
        campXRandom = mv.campX + (math.random(2) == 1 and -sd or sd)
    else
        campYRandom = mv.campY
        campXRandom = mv.campX
    end

    local myDist  = dist2D(campYRandom, campXRandom, mq.TLO.Me.Y(), mq.TLO.Me.X()) - 4
    local lcExp   = 0       -- os.clock() expiry for stuck-detection loc checks
    local dToggle = false   -- alternates underwater zigzag direction
    local _y0     = mv.campY - 20
    local _y1     = mv.campY + 20

    while true do
        if _state.session.iAmDead or mq.TLO.Me.Hovering() then
            mq.cmd('/squelch /moveto off')
            return
        end
        if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting()
           and dist2D(mv.campY, mv.campX, mq.TLO.Me.Y(), mq.TLO.Me.X()) >= 16 then
            mq.cmd('/stand')
        end

        if not (mq.TLO.Me.Moving() or mq.TLO.MoveTo.Moving()) then
            -- Not moving: issue the moveto command
            if mq.TLO.Me.FeetWet() then
                mq.cmdf('/face loc %f,%f,%f', campYRandom, campXRandom, mv.campZ)
                mq.cmd('/moveto set useback off')
                mq.cmdf('/squelch /moveto loc %f %f %f mdist 15', campYRandom, campXRandom, mv.campZ)
            else
                mq.cmd('/moveto set useback on')
                mq.cmdf('/squelch /moveto loc %f %f %f', campYRandom, campXRandom, mv.campZ)
            end
        elseif os.clock() >= lcExp then
            -- Periodic loc check: detect if stuck or snared
            local dc = dist2D(campYRandom, campXRandom, mq.TLO.Me.Y(), mq.TLO.Me.X())
            if dc > myDist then
                -- Stuck underwater: zigzag to break free
                if mq.TLO.Me.FeetWet() then
                    if mq.TLO.MoveTo.Moving() then mq.cmd('/squelch /moveto off'); mq.delay(50) end
                    local zigY = dToggle and _y1 or _y0
                    mq.cmdf('/face loc %f,%f,%f', zigY, campXRandom, mv.campZ)
                    mq.delay(50)
                    mq.cmdf('/squelch /moveto loc %f %f %f mdist 5', zigY, campXRandom, mv.campZ)
                    dToggle = not dToggle
                end
            else
                mq.cmdf('/face loc %f,%f,%f', campYRandom, campXRandom, mv.campZ)
            end
            myDist = dist2D(campYRandom, campXRandom, mq.TLO.Me.Y(), mq.TLO.Me.X()) - 4
            lcExp  = (mv.locDelayCheckUW and mq.TLO.Me.FeetWet()) and (os.clock() + 0.25) or 0
        end

        mq.delay(100)
        local dc2 = dist2D(campYRandom, campXRandom, mq.TLO.Me.Y(), mq.TLO.Me.X())
        if (not mq.TLO.MoveTo.Moving() and not mq.TLO.Me.Moving()) or os.clock() > timeout then break end
        if not mq.TLO.MoveTo.Moving() or dc2 < 16 then break end
    end

    -- Underwater: extra approach toward randomized point if still not close enough
    if mq.TLO.Me.FeetWet()
       and dist2D(campYRandom, campXRandom, mq.TLO.Me.Y(), mq.TLO.Me.X()) >= 15 then
        mq.cmdf('/face loc %f,%f,%f', campYRandom, campXRandom, mv.campZ)
        mq.cmdf('/squelch /moveto loc %f %f %f mdist 15', campYRandom, campXRandom, mv.campZ)
        local uwExp = os.clock() + 20
        while dist2D(campYRandom, campXRandom, mq.TLO.Me.Y(), mq.TLO.Me.X()) > 15
              and os.clock() < uwExp do
            mq.delay(50)
        end
        if mq.TLO.MoveTo.Moving() then mq.cmd('/squelch /moveto off') end
    end

    -- Settle, face, restore pitch
    mq.delay(200, function() return not mq.TLO.Me.Moving() end)
    if (mv.faceMobOn and _state.combat.aggroTargetID == '' and not _state.combat.combatStart)
       or not isPullerRole(role) then
        mq.cmdf('/face heading %d', mv.lookForward)
    end
    if not mq.TLO.Me.FeetWet() then mq.cmd('/look 0') end

    -- Outer underwater catch-all: approach with exact camp coords (mac:3649-3657)
    if mq.TLO.Me.FeetWet()
       and dist2D(mv.campY, mv.campX, mq.TLO.Me.Y(), mq.TLO.Me.X()) >= 15 then
        mq.cmdf('/face loc %f,%f,%f', mv.campY, mv.campX, mv.campZ)
        mq.cmdf('/squelch /moveto loc %f %f %f mdist 15', mv.campY, mv.campX, mv.campZ)
        local uwExp2 = os.clock() + 30
        while dist2D(mv.campY, mv.campX, mq.TLO.Me.Y(), mq.TLO.Me.X()) > 15
              and os.clock() < uwExp2 do
            mq.delay(50)
        end
        if mq.TLO.MoveTo.Moving() then mq.cmd('/squelch /moveto off') end
    end
end

-- Port of DoWeChase (kissassist.mac:3663-3813).
-- Follows WhoToChase using nav mesh (if loaded) or moveto/stick.
function Movement.doWeChase()
    local mv   = _state.movement
    local role = _state.session.role

    if not _state.session.chaseAssist then return end
    local chaseSpawn = mq.TLO.Spawn('=' .. mv.whoToChase)
    if mq.TLO.Me.Hovering() or (chaseSpawn.ID() or 0) == 0 then return end

    local chaseDistance = mv.chaseOnValue * _state.combat.meleeDistance
    local meshLoaded    = _state.pull.moveUse == 'nav' and (mq.TLO.Navigation.MeshLoaded() or false)

    -- Send pet to follow us while we chase
    if (mq.TLO.Me.Pet.ID() or 0) > 0
       and mq.TLO.Me.Pet.Stance() ~= 'FOLLOW' then
        mq.cmd('/pet follow')
    end

    while _state.session.chaseAssist do
        -- Stop chasing during combat if non-puller and not MA and target nearby
        if _state.movement.chaseOnValue == 1 then
            local spawnDist = (chaseSpawn.Distance() or 999)
            if (mq.TLO.SpawnCount('npc xtarhater')() or 0) > 0
               and not isPullerRole(role)
               and not _state.session.iAmMA
               and spawnDist < mv.campRadius then
                if mq.TLO.Stick.Active() then
                    mq.cmd('/squelch /stick off')
                    mq.cmd('/squelch /moveto off')
                end
                if meshLoaded and mq.TLO.Navigation.Active() then
                    mq.cmd('/squelch /nav stop')
                end
                break
            end
        end

        mq.doevents()

        -- Leash: disable ChaseAssist if target drifted too far
        local spawnID = chaseSpawn.ID() or 0
        if spawnID == 0 then break end
        local spawnDist = chaseSpawn.Distance() or 999
        local spawnDistZ = chaseSpawn.DistanceZ() or 0
        if not meshLoaded and _state.timers.justZoned <= os.clock() then
            if mv.campRadiusExceed > 0
               and (spawnDist > mv.campRadiusExceed or spawnDistZ > 100) then
                _state.session.chaseAssist = false
                printf('\ayChaseAssist distance exceeded: Turning off ChaseAssist.')
                break
            end
        end

        if spawnDist > chaseDistance then
            -- Target is farther than chaseDistance — move toward them
            if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then mq.cmd('/stand') end
            local chaseFailed = 0
            local loopExp     = os.clock() + 50

            while true do
                spawnID = chaseSpawn.ID() or 0
                if spawnID == 0 then break end
                if meshLoaded then
                    if not mq.TLO.Navigation.Active() then
                        if mq.TLO.Navigation.PathExists('id ' .. spawnID)() then
                            mq.cmdf('/squelch /nav id %d dist=%d', spawnID, chaseDistance)
                        elseif chaseSpawn.LineOfSight() then
                            mq.cmdf('/squelch /moveto id %d uw mdist %d', spawnID, chaseDistance)
                        else
                            chaseFailed = 1
                        end
                    end
                else
                    if chaseSpawn.LineOfSight() then
                        mq.cmdf('/squelch /moveto id %d uw mdist %d', spawnID, chaseDistance)
                    else
                        chaseFailed = 2
                    end
                end

                if os.clock() > loopExp then break end
                if chaseFailed > 0 then
                    if chaseFailed == 2 then
                        printf('\ayChase failed: %s not in LOS and no nav mesh. Exiting chase.', mv.whoToChase)
                    else
                        printf('\ayChase failed: no nav path to %s. Exiting chase.', mv.whoToChase)
                    end
                    _state.session.chaseAssist = false
                    break
                end

                mq.delay(50)
                if not mq.TLO.Me.Moving() then
                    local d = chaseSpawn.Distance() or 999
                    if d <= chaseDistance then break end
                end
                while mq.TLO.Me.Moving() do mq.delay(50) end
                local d2 = chaseSpawn.Distance() or 999
                if d2 > chaseDistance and chaseSpawn.LineOfSight() then
                    mq.cmdf('/moveto id %d uw mdist %d', spawnID, chaseDistance)
                else
                    break
                end
            end

        elseif not mq.TLO.Stick.Active() and not meshLoaded then
            -- Within chaseDistance but not sticking — start stick
            local uwFlag = mq.TLO.Me.FeetWet() and ' uw' or ''
            local spawnType = chaseSpawn.Type() or ''
            local stickID   = spawnID

            -- For pets/mercs, resolve to the controlling PC's ID
            if spawnType == 'Pet' then
                local masterName = chaseSpawn.Master() or ''
                local master = mq.TLO.Spawn('=' .. masterName)
                if (master.ID() or 0) > 0 then
                    mq.cmdf('/squelch /target id %d', master.ID())
                    mq.delay(100)
                    stickID = mq.TLO.Target.ID() or stickID
                end
            elseif spawnType == 'Mercenary' then
                local ownerName = chaseSpawn.Owner() or ''
                local owner = mq.TLO.Spawn('=' .. ownerName)
                if (owner.ID() or 0) > 0 then
                    mq.cmdf('/squelch /target id %d', owner.ID())
                    mq.delay(100)
                    stickID = mq.TLO.Target.ID() or stickID
                end
            end
            mq.cmdf('/squelch /stick %d id %d loose%s', chaseDistance, stickID, uwFlag)
            mq.delay(100)
            while mq.TLO.Me.Moving() do mq.delay(100) end
        end

        if not mq.TLO.Me.Moving() and not (chaseSpawn.Moving() or false) then break end
        if (chaseSpawn.Distance() or 999) <= chaseDistance then break end
    end
end

-- Port of Stuck (kissassist.mac:3817-3832).
-- Back up then strafe randomly to break out of geometry.
function Movement.stuck()
    if _state.session.iAmDead then return end
    mq.cmd('/keypress back hold')
    mq.delay(100)
    mq.cmd('/keypress back')
    local dir = math.random(2) == 1 and 'STRAFE_LEFT' or 'STRAFE_RIGHT'
    mq.cmdf('/keypress %s hold', dir)
    mq.delay(100)
    mq.cmdf('/keypress %s', dir)
end

-- Port of ZAxisCheck (kissassist.mac:12224-12235).
-- If levitation is pushing us above camp Z, press down to descend.
-- Returns true if Z-axis gap to camp exceeds campRadius+10 (guard for doWeMove).
function Movement.zAxisCheck()
    local mv = _state.movement
    local dz = mq.TLO.Me.Z() - mv.campZ  -- positive = above camp
    if not mq.TLO.Me.FeetWet() and dz >= 3.1 then
        mq.cmd('/keypress CMD_MOVE_DOWN hold')
        mq.delay(100, function() return (mq.TLO.Me.Z() - mv.campZ) <= 3.1 end)
        mq.cmd('/keypress CMD_MOVE_DOWN')
    end
    return math.abs(dz) > (mv.campRadius + 10)
end

-- Port of CheckStick (kissassist.mac:1879-1969).
-- Closes melee gap, issues /attack on, and sticks to myTargetID.
-- flag=0: use MaxRangeTo distance; flag=1: stick without distance (TargetOfTarget guard).
-- useAttack=1: issue /attack on if not already in combat.
function Movement.checkStick(flag, useAttack)
    local mv   = _state.movement
    local comb = _state.combat
    local sess = _state.session

    -- When chasing or not anchored, use MA position as the camp reference
    local refY, refX = mv.campY, mv.campX
    if sess.chaseAssist or not mv.returnToCamp then
        local ma = mq.TLO.Spawn('=' .. sess.mainAssist)
        if (ma.ID() or 0) > 0 then
            refY = ma.Y() or refY
            refX = ma.X() or refX
        end
    end

    local myID = comb.myTargetID
    if myID == 0 then return end
    local mob  = mq.TLO.Spawn('id ' .. myID)
    local maDist = comb.meleeDistance
    local cr     = mv.campRadius

    -- Gap-close and stick when: no camp set (free-roam) OR MeleeDistance > CampRadius
    if not mv.returnToCamp or maDist > cr then
        local mobY = mob.Y() or 0
        local mobX = mob.X() or 0

        -- "Mob too far from camp" guard only applies in camp mode
        if mv.returnToCamp and dist2D(refY, refX, mobY, mobX) > maDist then
            local ma    = mq.TLO.Spawn('=' .. sess.mainAssist)
            local maY   = ma.Y() or 0
            local maX   = ma.X() or 0
            if dist2D(refY, refX, maY, maX) > maDist then return end
            if dist2D(mobY, mobX, maY, maX) > cr then return end
        end

        -- Close to melee range if mob is farther than MaxRangeTo
        local maxRange = mob.MaxRangeTo() or 0
        local _dist    = math.max(1, maxRange - 2)
        if maxRange > 0 and maxRange < (mob.Distance() or 999) then
            if _state.pull.moveUse == 'nav' then
                local navExp = os.clock() + 30
                while os.clock() < navExp do
                    if not mq.TLO.Navigation.Active() then
                        mq.cmdf('/squelch /nav id %d dist=%d', myID, _dist)
                    end
                    if (mob.MaxRangeTo() or 0) >= (mob.Distance() or 999) then break end
                    mq.delay(50)
                end
                if mq.TLO.Navigation.Active() then mq.cmd('/nav stop') end
            end
            if mob.LineOfSight() then
                mq.cmdf('/moveto id %d dist %d', myID, _dist)
            end
        end
    end

    -- Attack: enable auto-attack if not already in combat
    if (useAttack or 0) ~= 0 then
        if not mq.TLO.Me.Combat() and (mq.TLO.Target.ID() or 0) ~= 0 then
            local st = mq.TLO.Me.State() or ''
            if st == 'stand' or st == 'mount' then
                mq.cmd('/squelch /attack on')
            end
        end
    end

    -- Stick to target; in camp mode only when MeleeDistance > CampRadius
    if mv.returnToCamp and maDist <= cr then return end
    local stickHow = mv.dStickHow
    if stickHow == 'I' then return end

    local maxRange = mob.MaxRangeTo() or maDist
    local uw       = mq.TLO.Me.FeetWet() and ' uw' or ''

    if stickHow ~= '0' then
        -- Directional stick modifier (d=behind, mp=moveback)
        if (flag or 0) == 0 then
            mq.cmdf('/stick %d id %d %s%s', maxRange - 3, myID, stickHow, uw)
        elseif (flag or 0) == 1 then
            if (mq.TLO.Target.ID() or 0) ~= 0
               and (mq.TLO.Me.TargetOfTarget.ID() or 0) ~= mq.TLO.Me.ID() then
                mq.cmdf('/stick id %d %s%s', myID, stickHow, uw)
            end
        end
    else
        -- Plain stick (no directional modifier)
        if (flag or 0) == 0 then
            mq.cmdf('/stick %d id %d%s', maxRange, myID, uw)
        elseif (flag or 0) == 1 then
            if (mq.TLO.Target.ID() or 0) ~= 0
               and (mq.TLO.Me.TargetOfTarget.ID() or 0) ~= mq.TLO.Me.ID() then
                mq.cmdf('/stick id %d%s', myID, uw)
            end
        end
    end
end

return Movement
