-- tests/unit/test_forced_target.lua
-- The forced target (/kactl target, phase 4 #364) in target selection:
-- Util.forcedTarget clears a dead or gone target; assist (non-MA) and
-- getCombatTarget (MA) lock onto it wherever it is, ahead of their own picks;
-- combatTargetCheck keeps it against the group assist target; backoff (DPS
-- paused) still wins; a dead forced target hands back to normal picking.
-- Engaging it (step 3): fight()'s rangeCheck counts it in range; closeInOnForced
-- moves to it (melee range, or line of sight for a caster), not while holding,
-- and stops when it stops being the forced target; doWeMove doesn't walk back
-- to camp while it's alive.
local M = {}

local SUBMODULES = {
    'modules.combat.settings', 'modules.combat.util', 'modules.combat.abilities',
    'modules.combat.radar', 'modules.combat.targeting', 'modules.combat.fight',
}

function M.run(TH, MockMQ)
    TH.setSuite('test_forced_target')
    MockMQ.reset()
    for _, m in ipairs(SUBMODULES) do package.loaded[m] = nil end
    local Util      = require('modules.combat.util')
    local Targeting = require('modules.combat.targeting')

    local state = {
        misc     = { dmz = false },
        combat   = { meleeOn = true, dpsOn = true, myTargetID = 0, myTargetName = '', lastTargetID = 0,
                     mobCount = 1, aggroTargetID = '7', forcedTargetID = 0, manualTargetMode = false,
                     targetSwitchingOn = false, calledTargetID = 0, petTargetSwitch = false,
                     xTSlot2 = 0, meleeDistance = 75 },
        mez      = { on = 0, mobFlag = false },
        dps      = { paused = false },
        pull     = { pulled = false },
        session  = { role = 'tank', mainAssist = 'Tank', iAmMA = true },
        movement = { campX = 0, campY = 0, returnToCamp = true, campRadius = 30 },
    }
    Util.init(state)
    local radarCalls = 0
    Targeting.init(state, { debug = function() end }, { mobRadar = function() radarCalls = radarCalls + 1 end })

    -- Spawns: 42 is the forced NPC, far from camp; 7 is a hater in camp. A spawn
    -- in `dead` reads as a corpse; one in `gone` doesn't exist.
    local dead, gone = {}, {}
    local currentTarget = 0
    local farDist, farLOS = 300, true  -- mob 42's distance and line of sight
    MockMQ.set('TLO.Spawn', function(q)
        local id = tonumber(tostring(q):match('id (%d+)')) or 0
        return {
            ID          = function() return (gone[id] or id == 0) and 0 or id end,
            Type        = function() return dead[id] and 'Corpse' or 'NPC' end,
            CleanName   = function() return id == 42 and 'a far mob' or 'a camp mob' end,
            Distance    = function() return id == 42 and farDist or 10 end,
            Distance3D  = function() return id == 42 and farDist or 10 end,
            MaxRangeTo  = function() return 14 end,
            LineOfSight = function() return id ~= 42 or farLOS end,
            PctHPs      = function() return 100 end,
            Y           = function() return 0 end,
            X           = function() return id == 42 and farDist or 0 end,
        }
    end)
    MockMQ.set('TLO.Target.ID', function() return currentTarget end)
    MockMQ.set('TLO.Target.CleanName', function() return '' end)
    MockMQ.set('TLO.Me.CleanName', function() return 'Me' end)
    local savedCmd = MockMQ.cmd
    MockMQ.cmd = function(c)
        savedCmd(c)
        local id = tonumber(c:match('/target id (%d+)'))
        if id then currentTarget = id end
    end

    -- ── Util.forcedTarget ───────────────────────────────────────────────────
    TH.assert_eq(Util.forcedTarget(), 0, 'forcedTarget: 0 when none')
    state.combat.forcedTargetID = 42
    TH.assert_eq(Util.forcedTarget(), 42, 'forcedTarget: the ID while alive')
    dead[42] = true
    TH.assert_eq(Util.forcedTarget(), 0, 'forcedTarget: 0 once it is a corpse')
    TH.assert_eq(state.combat.forcedTargetID, 0, 'forcedTarget: a dead target is cleared')
    dead[42] = nil
    state.combat.forcedTargetID = 42
    gone[42] = true
    TH.assert_eq(Util.forcedTarget(), 0, 'forcedTarget: 0 once despawned')
    TH.assert_eq(state.combat.forcedTargetID, 0, 'forcedTarget: a despawned target is cleared')
    gone[42] = nil

    -- ── getCombatTarget (MA) ────────────────────────────────────────────────
    state.combat.forcedTargetID = 42
    radarCalls = 0
    Targeting.getCombatTarget()
    TH.assert_eq(state.combat.myTargetID, 42, 'getCombatTarget: locks onto the forced target (300 away)')
    TH.assert_eq(currentTarget, 42, 'getCombatTarget: targets it')
    TH.assert_eq(state.combat.myTargetName, 'a far mob', 'getCombatTarget: name set')
    TH.assert_eq(radarCalls, 0, 'getCombatTarget: skips its own pick')

    state.combat.myTargetID = 7
    state.pull.pulled = true
    Targeting.getCombatTarget()
    TH.assert_eq(state.combat.myTargetID, 42, 'getCombatTarget: forced target wins over a pulled mob')
    state.pull.pulled = false

    state.dps.paused = true
    state.combat.myTargetID = 0
    Targeting.getCombatTarget()
    TH.assert_eq(state.combat.myTargetID, 0, 'getCombatTarget: backoff still wins')
    state.dps.paused = false

    -- ── assist (non-MA) ─────────────────────────────────────────────────────
    state.session.iAmMA, state.session.role = false, 'assist'
    state.combat.myTargetID, currentTarget = 0, 7
    Targeting.assist('test')
    TH.assert_eq(state.combat.myTargetID, 42, "assist: forced target instead of the MA's")
    TH.assert_eq(currentTarget, 42, 'assist: targets it')

    -- ── combatTargetCheck ───────────────────────────────────────────────────
    -- Group MA set, with a group assist target of 7: without a forced target a
    -- non-MA would sync to 7.
    MockMQ.set('TLO.Group.MainAssist.ID', function() return 5 end)
    MockMQ.set('TLO.Me.GroupAssistTarget.ID', function() return 7 end)
    state.combat.myTargetID, currentTarget = 7, 7
    Targeting.combatTargetCheck(1)
    TH.assert_eq(state.combat.myTargetID, 42, 'combatTargetCheck: back on the forced target')
    TH.assert_eq(currentTarget, 42, 'combatTargetCheck: re-targets it')

    state.session.iAmMA, state.session.role = true, 'tank'
    state.combat.targetSwitchingOn = true
    currentTarget = 7
    Targeting.combatTargetCheck(1)
    TH.assert_eq(state.combat.myTargetID, 42, 'combatTargetCheck: MA with TargetSwitchingOn keeps the forced target')
    state.combat.targetSwitchingOn = false

    state.dps.paused = true
    state.combat.myTargetID = 7
    Targeting.combatTargetCheck(1)
    TH.assert_eq(state.combat.myTargetID, 7, 'combatTargetCheck: no re-lock while backed off')
    Targeting.combatTargetCheck(2)
    TH.assert_eq(state.combat.myTargetID, 42, 'combatTargetCheck 2 (bypass backoff): re-locks')
    state.dps.paused = false

    -- ── forced target dies: normal picking resumes ──────────────────────────
    dead[42] = true
    state.combat.myTargetID = 42
    Targeting.combatTargetCheck(1)
    TH.assert_eq(state.combat.forcedTargetID, 0, 'dead forced target: cleared')
    TH.assert_eq(state.combat.myTargetID, 0, 'dead forced target: myTargetID cleared as usual')
    -- No haters and no target, so the pick runs its radar and finds nothing.
    state.combat.mobCount, state.combat.aggroTargetID, currentTarget = 0, '', 0
    radarCalls = 0
    Targeting.getCombatTarget()
    TH.assert_eq(radarCalls, 1, 'after it dies: getCombatTarget picks for itself again')
    TH.assert_eq(state.combat.myTargetID, 0, 'after it dies: nothing to pick, no target')

    -- ── step 3: engaging it ─────────────────────────────────────────────────
    package.loaded['modules.combat.fight'] = nil
    local Fight = require('modules.combat.fight')
    Fight.init(state, { debug = function() end })
    dead[42] = nil  -- alive again after the "forced target dies" checks above
    state.combat.forcedTargetID, farDist, farLOS = 42, 300, true
    TH.assert_true(Fight.rangeCheck(42, 20), 'rangeCheck: the forced target is in range 300 away')
    state.combat.forcedTargetID = 0
    TH.assert_false(Fight.rangeCheck(42, 20), 'rangeCheck: the same mob is out of range when not forced')
    state.combat.forcedTargetID = 42

    -- closeInOnForced: each mq.delay brings the mob 100 closer.
    local savedDelay = MockMQ.delay
    local delays = 0
    MockMQ.delay = function() delays = delays + 1; farDist = math.max(farDist - 100, 0) end
    MockMQ.set('TLO.Navigation.MeshLoaded', function() return false end)
    MockMQ.set('TLO.MoveTo.Moving', function() return false end)
    local cmds = {}
    local savedCmdf = MockMQ.cmdf
    MockMQ.cmd = function(c) cmds[#cmds + 1] = c end
    MockMQ.cmdf = function(fmt, ...) cmds[#cmds + 1] = string.format(fmt, ...) end
    local function sent(pat)
        for _, c in ipairs(cmds) do if c:find(pat) then return true end end
        return false
    end

    Fight.closeInOnForced(42)
    TH.assert_true(sent('/moveto id 42 dist 12'), 'closeIn: moves to the forced target (MaxRangeTo - 2)')
    TH.assert_eq(farDist, 0, 'closeIn: keeps moving until in melee range')

    cmds, farDist = {}, 300
    state.session.hold = true
    Fight.closeInOnForced(42)
    TH.assert_eq(#cmds, 0, 'closeIn: no movement while holding')
    state.session.hold = false

    cmds, farDist, delays = {}, 300, 0
    state.combat.meleeOn = false
    Fight.closeInOnForced(42)
    TH.assert_eq(#cmds, 0, 'closeIn: a caster with line of sight stays put')
    farLOS = false
    MockMQ.delay = function() delays = delays + 1; farLOS = true end
    Fight.closeInOnForced(42)
    TH.assert_true(sent('/moveto id 42'), 'closeIn: a caster without line of sight moves')
    TH.assert_eq(delays, 1, 'closeIn: a caster stops once it has line of sight')
    state.combat.meleeOn = true

    cmds, farDist, delays = {}, 300, 0
    MockMQ.delay = function() delays = delays + 1; state.combat.forcedTargetID = 0 end
    Fight.closeInOnForced(42)
    TH.assert_eq(delays, 1, 'closeIn: stops when the forced target is cleared mid-move')
    state.combat.forcedTargetID = 42

    -- ── doWeMove: no camp walk while the forced target is alive ─────────────
    local savedCfg = package.loaded['modules.config']
    package.loaded['modules.config'] = { get = function(_, _, d) return d end }
    package.loaded['modules.movement'] = nil
    local Movement = require('modules.movement')
    local mstate = {
        session  = { role = 'tank', paused = false },
        combat   = { forcedTargetID = 42 },
        movement = { returnToCamp = true, campX = 0, campY = 0 },
        pull     = {},
    }
    Movement.init(mstate)
    mstate.movement.campX, mstate.movement.campY, mstate.movement.campZone = 5, 5, 1
    local savedEvents = MockMQ.doevents
    local events = 0
    MockMQ.doevents = function() events = events + 1 end
    MockMQ.set('TLO.Me.Y', function() return 5 end)
    MockMQ.set('TLO.Me.X', function() return 5 end)
    MockMQ.set('TLO.Zone.ID', function() return 1 end)
    Movement.doWeMove(1, 'test')
    TH.assert_eq(events, 0, 'doWeMove: returns at once while the forced target is alive')
    dead[42] = true
    Movement.doWeMove(1, 'test')
    TH.assert_eq(events, 1, 'doWeMove: runs again once the forced target is dead')
    dead[42] = nil

    MockMQ.doevents = savedEvents
    MockMQ.delay = savedDelay
    MockMQ.cmdf = savedCmdf
    package.loaded['modules.config'] = savedCfg
    package.loaded['modules.movement'] = nil
    MockMQ.cmd = savedCmd
    for _, m in ipairs(SUBMODULES) do package.loaded[m] = nil end
end

return M
