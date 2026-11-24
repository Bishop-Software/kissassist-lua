-- modules/campfire.lua
-- Fellowship campfire handling from kissassist.mac:
--   Campfire.check()        Sub Campfire (mac:12855): place one at camp when out of
--                           combat and 3+ fellowship members are near ([General] CampfireOn)
--   Campfire.place()        Bind_Campfire (mac:11840): the Fellowship window sequence
--                           (also the /campfire command)
--   Campfire.back()         Sub CampfireBack (mac:13392): dead and out of the camp zone,
--                           click the Fellowship Registration Insignia back to the
--                           campfire ([AFKTools] ClickBacktoCamp)
--   Campfire.hoverRespawn() PauseWhileHovering's puller branch (mac:15979): a puller
--                           who died far from camp respawns at bind when the Insignia
--                           is ready, so it can click back
-- The mac's waits are blocking loops; back() and hoverRespawn() are non-blocking
-- (one step per main-loop pass). place() blocks briefly, like the mac, but only runs
-- out of combat.

local mq     = require('mq')
local Config = require('modules.config')

local Campfire = {}
local _state, _movement

local INSIGNIA  = 'Fellowship Registration Insignia'
local MATERIALS = 'Fellowship Campfire Materials'
local NO_CAMPFIRE_ZONES = { [33506] = true }  -- mac:11843

function Campfire.init(state, movement)
    _state, _movement = state, movement
    state.misc.campfireOn     = tonumber(Config.get('General', 'CampfireOn', '0')) or 0
    if state.misc.campfireOn > 0 then state.misc.campfireKit = state.misc.campfireOn end
    state.afk.clickBacktoCamp = tonumber(Config.get('AFKTools', 'ClickBacktoCamp', '0')) or 0
end

-- ── Pure decisions (unit-tested) ─────────────────────────────────────────────

-- Sub Campfire (mac:12856-12867). snap fields: campfireOn, now, timer, zoneID,
-- campfireZoneID, campfireZoneName, distToCamp, campRadius, aggro, combatStart,
-- fellowsNear. Returns 'place', 'retry' (not enough fellowship members: try
-- again in 5 minutes) or nil.
function Campfire.decidePlace(snap)
    if (snap.campfireOn or 0) == 0 then return nil end
    if (snap.timer or 0) > snap.now then return nil end
    local cz = snap.campfireZoneID or 0
    if cz ~= 0 and (cz == snap.zoneID or (snap.campfireZoneName or ''):lower():find('guild hall', 1, true)) then
        return nil
    end
    if snap.distToCamp > snap.campRadius then return nil end
    if snap.aggro or snap.combatStart then return nil end
    if (snap.fellowsNear or 0) >= 3 then return 'place' end
    return 'retry'
end

-- Sub CampfireBack (mac:13396-13443). snap fields: clickBack, now, timer, campZone,
-- zoneID, revivalSickness, hasCampfire, campfireZoneID, hasInsignia, insigniaReady,
-- rested. Returns nil (nothing to do), 'none' (no campfire), 'samezone' (back in the
-- campfire's zone), 'noinsignia', 'wait' (Insignia not ready or not yet out of
-- combat) or 'click'.
function Campfire.decideBack(snap)
    if (snap.clickBack or 0) == 0 then return nil end
    if (snap.timer or 0) > snap.now then return nil end
    if snap.campZone == snap.zoneID then return nil end
    if not snap.revivalSickness then return nil end
    if not snap.hasCampfire then return 'none' end
    if snap.campfireZoneID == snap.zoneID then return 'samezone' end
    if not snap.hasInsignia then return 'noinsignia' end
    if not snap.insigniaReady or not snap.rested then return 'wait' end
    return 'click'
end

-- ── Live wrappers ────────────────────────────────────────────────────────────

local function campDist()
    local mv = _state.movement
    local dx, dy = (mq.TLO.Me.X() or 0) - (mv.campX or 0), (mq.TLO.Me.Y() or 0) - (mv.campY or 0)
    return math.sqrt(dx * dx + dy * dy)
end

local function hasCampfire() return mq.TLO.Me.Fellowship.Campfire() == true end

-- Bind_Campfire (mac:11840). Returns true if a campfire is up afterwards.
-- The /campfire command uses type 1 when CampfireOn is 0 (the mac returns).
function Campfire.place()
    local s = _state
    local useType = math.max(1, s.misc.campfireOn or 0)
    if NO_CAMPFIRE_ZONES[mq.TLO.Zone.ID() or 0] then return false end
    if (mq.TLO.Me.Fellowship.ID() or 0) == 0 then
        printf('\ayCampfire: you are not in a fellowship.')
        return false
    end
    if s.movement.returnToCamp and _movement then _movement.doWeMove(1, 'campfire') end
    if useType > 1 and (mq.TLO.FindItemCount('=' .. MATERIALS)() or 0) < 1 then
        useType = 1
        printf('\ay%s Not Found. Setting to Regular Fellowship.', MATERIALS)
    end
    mq.cmd('/windowstate FellowshipWnd open')
    mq.delay(1000)
    mq.cmd('/nomodkey /notify FellowshipWnd FP_Subwindows tabselect 2')
    -- A campfire in another zone has to go first (mac:11854-11863)
    if hasCampfire() and (mq.TLO.Me.Fellowship.CampfireZone.ID() or 0) ~= (mq.TLO.Zone.ID() or 0) then
        mq.cmd('/nomodkey /notify FellowshipWnd FP_DestroyCampsite leftmouseup')
        mq.delay(5000, function() return mq.TLO.Window('ConfirmationDialogBox').Open() == true end)
        if mq.TLO.Window('ConfirmationDialogBox').Open() then
            mq.cmd('/nomodkey /notify ConfirmationDialogBox Yes_Button leftmouseup')
        end
        mq.delay(5000, function() return not hasCampfire() end)
    end
    mq.cmd('/nomodkey /notify FellowshipWnd FP_RefreshList leftmouseup')
    mq.delay(1000)
    mq.cmdf('/nomodkey /notify FellowshipWnd FP_CampsiteKitList listselect %d', useType)
    mq.delay(1000)
    mq.cmd('/nomodkey /notify FellowshipWnd FP_CreateCampsite leftmouseup')
    mq.delay(5000, hasCampfire)
    mq.cmd('/windowstate FellowshipWnd close')
    if hasCampfire() then
        printf('\agCampfire Dropped')
        return true
    end
    return false
end

-- Sub Campfire (mac:12855), called from the main loop out of combat.
function Campfire.check()
    local s = _state
    local now = os.clock()
    local action = Campfire.decidePlace({
        campfireOn       = s.misc.campfireOn,
        now              = now,
        timer            = s.timers.campfire,
        zoneID           = mq.TLO.Zone.ID() or 0,
        campfireZoneID   = mq.TLO.Me.Fellowship.CampfireZone.ID() or 0,
        campfireZoneName = mq.TLO.Me.Fellowship.CampfireZone.Name() or '',
        distToCamp       = campDist(),
        campRadius       = s.movement.campRadius or 0,
        aggro            = (s.combat.aggroTargetID or '') ~= '' and s.combat.aggroTargetID ~= '0',
        combatStart      = s.combat.combatStart,
        fellowsNear      = mq.TLO.SpawnCount('pc radius 50 fellowship')() or 0,
    })
    if action == 'place' then
        Campfire.place()
    elseif action == 'retry' then
        printf('\ayNot enough fellowship members trying again in 5 minutes')
        s.timers.campfire = now + 300
    end
end

-- Sub CampfireBack (mac:13392), called from the main loop. One step per pass.
function Campfire.back()
    local s = _state
    local now = os.clock()
    local fs = mq.TLO.Me.Fellowship
    local action = Campfire.decideBack({
        clickBack       = s.afk.clickBacktoCamp,
        now             = now,
        timer           = s.timers.campfireClick,
        campZone        = s.movement.campZone,
        zoneID          = mq.TLO.Zone.ID() or 0,
        revivalSickness = (mq.TLO.Me.Buff('Revival Sickness').ID() or 0) ~= 0,
        hasCampfire     = fs.Campfire() == true,
        campfireZoneID  = fs.CampfireZone.ID() or 0,
        hasInsignia     = (mq.TLO.FindItemCount('=' .. INSIGNIA)() or 0) > 0,
        insigniaReady   = (mq.TLO.FindItem('=' .. INSIGNIA).TimerReady() or 1) == 0,
        rested          = ({ ACTIVE = true, RESTING = true })[(mq.TLO.Me.CombatState() or ''):upper()] == true,
    })
    if not action then return end
    if action == 'wait' then
        if (s.timers.campfireWaitMsg or 0) <= now then
            printf('\ayWaiting for %s to refresh.', INSIGNIA)
            s.timers.campfireWaitMsg = now + 10
        end
        return
    end
    if action == 'none' then
        printf('\ayThere is no campfire up.')
    elseif action == 'samezone' then
        printf('\agI\'m back in the same zone as my campfire.')
        s.session.iAmDead = false
    elseif action == 'noinsignia' then
        printf('\ayYou Don\'t have a %s. You may want to go get one.', INSIGNIA)
    elseif action == 'click' then
        printf('\agTime to get back to work. Clicking %s.', INSIGNIA)
        mq.cmdf('/squelch /nomodkey /itemnotify "%s" rightmouseup', INSIGNIA)
    end
    s.timers.campfireClick = now + 60  -- CampfireClickTimer 1m (mac:13445)
end

-- PauseWhileHovering's puller branch (mac:15979-15992): a puller who died more
-- than 150 from camp respawns at bind once the Insignia is ready.
function Campfire.hoverRespawn()
    local s = _state
    if (s.afk.clickBacktoCamp or 0) == 0 or not s.movement.returnToCamp then return end
    if not (s.session.role or ''):lower():find('puller', 1, true) then return end
    if campDist() <= 150 then return end
    if not mq.TLO.Me.ItemReady('=' .. INSIGNIA)() then return end
    if (s.timers.campfireRespawn or 0) > os.clock() then return end
    if not mq.TLO.Window('respawnWnd').Open() then return end
    local idx = mq.TLO.Window('respawnWnd').Child('RW_OptionsList').List('=Bind Location', 2)() or 0
    if idx == 0 then return end
    mq.cmdf('/nomodkey /notify respawnWnd RW_OptionsList listselect %d', idx)
    mq.delay(1000)
    mq.cmd('/nomodkey /notify respawnWnd RW_SelectButton leftmouseup')
    s.timers.campfireRespawn = os.clock() + 5
end

return Campfire
