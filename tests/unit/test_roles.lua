-- tests/unit/test_roles.lua
-- Tests modules/roles.lua (#322): checkRoles per role, the MezDebuffOnResist
-- check, the INI baseline, and switchMA (mac CheckRoles / Bind_SwitchMA).
local M = {}

function M.run(TH, MockMQ)
    local Roles = require('modules.roles')

    TH.setSuite('test_roles')

    local calls        -- stub call counts
    local _            -- unused setup() results
    local broadcasts   -- comms.broadcast payloads

    local function newState(role)
        return {
            session  = { role = role, myOriginalRole = role, mainAssist = '', iAmMA = false, chaseAssist = false },
            combat   = { assistAt = 95, meleeOn = true, dpsOn = true, dpsOnOoc = false,
                         useMQ2Melee = false, calledTargetID = 42 },
            buffs    = { buffsOn = true },
            heal     = { healsOn = 1 },
            mez      = { on = 0, mezDebuffOnResist = false, mezDebuffSpell = '' },
            debuff   = { on = 1 },
            pet      = { assistAt = 95 },
            misc     = { mountOn = true },
            movement = { campRadiusExceed = 400, campX = 0, campY = 0, campRadius = 30,
                         dStickHow = 'snaproll', returnToCamp = true },
            pull     = { maxRadius = 350 },
        }
    end

    -- Wires Roles to a fresh state and stubs; returns state, cmd recorder, sent list.
    local function setup(role)
        MockMQ.reset()
        MockMQ.set('TLO.Me.CleanName', 'Toon')
        MockMQ.set('TLO.Me.Pet.ID', 0)
        calls = { puller = 0, hunter = 0, stick = 0, reset = 0 }
        broadcasts = {}
        local st = newState(role)
        Roles.init(st,
            { debug = function() end },
            { setupPullerRole = function() calls.puller = calls.puller + 1 end,
              setupHunterRole = function() calls.hunter = calls.hunter + 1 end },
            { resolveStickHow = function() calls.stick = calls.stick + 1 end },
            { combatReset = function() calls.reset = calls.reset + 1 end },
            { broadcast = function(t, d) broadcasts[#broadcasts + 1] = { t = t, d = d } end })
        local sent = {}
        return st, function(c) sent[#sent + 1] = c end, sent
    end

    local function has(list, item)
        for _, v in ipairs(list) do if v == item then return true end end
        return false
    end

    -- ── assist / offtank ────────────────────────────────────────────────────
    local st, rec, sent = setup('assist')
    st.combat.useMQ2Melee = true
    Roles.checkRoles(1, rec)
    TH.assert_true(has(sent, '/squelch /melee aggro=0') and has(sent, '/stick mod 0'),
        'assist + MQ2Melee: aggro=0 and /stick mod 0')
    TH.assert_eq(calls.stick, 1, 'checkRoles always resolves StickHow')

    _, rec, sent = setup('offtank')
    Roles.checkRoles(1, rec)
    TH.assert_true(has(sent, '/stick mod 0'), 'offtank, melee on: /stick mod 0')
    TH.assert_false(has(sent, '/squelch /melee aggro=0'), 'offtank without MQ2Melee: no aggro command')

    st, rec, sent = setup('assist')
    st.combat.meleeOn, st.combat.dpsOn = false, false
    Roles.checkRoles(1, rec)
    TH.assert_eq(#sent, 0, 'assist with melee and DPS off: no stick command')

    -- ── tank ────────────────────────────────────────────────────────────────
    st, rec, sent = setup('tank')
    Roles.checkRoles(1, rec)
    TH.assert_eq(st.combat.assistAt, 100, 'tank: assistAt 100')
    TH.assert_true(has(sent, '/stick mod -2'), 'tank without MQ2Melee: /stick mod -2')
    st, rec, sent = setup('tank')
    st.combat.useMQ2Melee = true
    Roles.checkRoles(1, rec)
    TH.assert_true(has(sent, '/squelch /melee aggro=1'), 'tank + MQ2Melee: aggro=1')
    TH.assert_false(has(sent, '/stick mod -2'), 'tank + MQ2Melee: no /stick mod')

    -- ── puller / hunter roles call pull/roles.lua ───────────────────────────
    _, rec, sent = setup('puller')
    Roles.checkRoles(1, rec)
    TH.assert_eq(calls.puller, 1, 'puller: setupPullerRole called')
    TH.assert_true(has(sent, '/stick mod 0'), 'puller: /stick mod 0')
    st, rec, sent = setup('pullertank')
    st.movement.dStickHow = 'auto'
    Roles.checkRoles(1, rec)
    TH.assert_true(has(sent, '/stick mod -2'), 'pullertank, StickHow auto: /stick mod -2')
    st, rec, sent = setup('pullertank')
    st.movement.dStickHow = 'behind'
    Roles.checkRoles(1, rec)
    TH.assert_false(has(sent, '/stick mod -2'), 'pullertank, StickHow set: no /stick mod')
    _, rec = setup('pullerpettank')
    Roles.checkRoles(1, rec)
    TH.assert_eq(calls.puller, 1, 'pullerpettank: setupPullerRole called')
    st, rec, sent = setup('hunter')
    st.movement.dStickHow = '0'
    Roles.checkRoles(1, rec)
    TH.assert_eq(calls.hunter, 1, 'hunter: setupHunterRole called')
    TH.assert_true(has(sent, '/stick mod -2'), 'hunter, StickHow auto (0): /stick mod -2')
    _, rec = setup('hunterpettank')
    Roles.checkRoles(1, rec)
    TH.assert_eq(calls.hunter, 1, 'hunterpettank: setupHunterRole called')
    TH.assert_eq(calls.puller, 0, 'hunterpettank: setupPullerRole not called')

    -- ── petassist ───────────────────────────────────────────────────────────
    st, rec, sent = setup('petassist')
    st.combat.useMQ2Melee = true
    Roles.checkRoles(1, rec)
    TH.assert_false(st.combat.meleeOn, 'petassist: melee off')
    TH.assert_true(has(sent, '/squelch /melee aggro=0'), 'petassist + MQ2Melee: aggro=0')

    -- ── pettank ─────────────────────────────────────────────────────────────
    st, rec, sent = setup('pettank')
    Roles.checkRoles(1, rec)
    TH.assert_eq(st.combat.assistAt, 100, 'pettank: assistAt 100')
    TH.assert_eq(st.pet.assistAt, 100, 'pettank: pet assistAt 100')
    TH.assert_false(st.misc.mountOn, 'pettank: mount off')
    TH.assert_eq(st.movement.campRadiusExceed, 550, 'pettank: leash = MaxRadius + 200')
    TH.assert_false(has(sent, '/pet guard') or has(sent, '/pet follow'), 'pettank, no pet: no pet command')

    _, rec, sent = setup('pettank')
    MockMQ.set('TLO.Me.Pet.ID', 7)
    MockMQ.set('TLO.Me.Pet.Distance', 10)
    Roles.checkRoles(1, rec)
    TH.assert_true(has(sent, '/pet guard'), 'pettank, no camp yet, pet close to me: /pet guard')
    st, rec, sent = setup('pettank')
    MockMQ.set('TLO.Me.Pet.ID', 7)
    st.movement.campX, st.movement.campY = 100, 100
    MockMQ.set('TLO.Me.Pet.X', 200)
    MockMQ.set('TLO.Me.Pet.Y', 100)
    Roles.checkRoles(1, rec)
    TH.assert_true(has(sent, '/pet follow'), 'pettank, pet 100 from camp: /pet follow')

    -- ── manual ──────────────────────────────────────────────────────────────
    st, rec = setup('manual')
    Roles.checkRoles(1, rec)
    TH.assert_true(not st.combat.meleeOn and not st.combat.dpsOn and not st.buffs.buffsOn,
        'manual: melee, DPS, buffs off')
    TH.assert_true(not st.movement.returnToCamp and not st.session.chaseAssist,
        'manual: camp and chase off')
    TH.assert_eq(st.heal.healsOn, 0, 'manual: heals off')
    TH.assert_eq(st.mez.on, 0, 'manual: mez off')
    TH.assert_eq(st.debuff.on, 0, 'manual: debuffs off')

    -- ── MezDebuffOnResist check (mac:8844) ──────────────────────────────────
    local realAvail = Roles.spellAvailable
    st, rec = setup('assist')
    st.mez.on, st.mez.mezDebuffOnResist, st.mez.mezDebuffSpell = 1, true, 'Bite of Tashan'
    Roles.spellAvailable = function() return false end
    Roles.checkRoles(1, rec)
    TH.assert_false(st.mez.mezDebuffOnResist, 'MezDebuffOnResist: spell missing → turned off')
    st, rec = setup('assist')
    st.mez.on, st.mez.mezDebuffOnResist, st.mez.mezDebuffSpell = 1, true, 'Bite of Tashan'
    Roles.spellAvailable = function() return true end
    Roles.checkRoles(1, rec)
    TH.assert_true(st.mez.mezDebuffOnResist, 'MezDebuffOnResist: spell available → stays on')
    st, rec = setup('assist')
    st.mez.on, st.mez.mezDebuffOnResist, st.mez.mezDebuffSpell = 0, true, ''
    Roles.spellAvailable = function() return false end
    Roles.checkRoles(1, rec)
    TH.assert_true(st.mez.mezDebuffOnResist, 'MezDebuffOnResist: mez off → not checked')
    Roles.spellAvailable = realAvail

    -- ── baseline ────────────────────────────────────────────────────────────
    st = setup('assist')
    st.session.myOriginalRole = nil
    Roles.saveBaseline()
    TH.assert_eq(st.session.myOriginalRole, 'assist', 'saveBaseline records the original role')
    st.combat.assistAt, st.heal.healsOn, st.misc.mountOn = 100, 0, false
    st.movement.returnToCamp = false
    Roles.restoreBaseline()
    TH.assert_eq(st.combat.assistAt, 95, 'restoreBaseline: assistAt back to the INI value')
    TH.assert_eq(st.heal.healsOn, 1, 'restoreBaseline: healsOn back')
    TH.assert_true(st.misc.mountOn, 'restoreBaseline: mountOn back')
    TH.assert_false(st.movement.returnToCamp, 'restoreBaseline: live ReturnToCamp left alone')

    -- ── switchMA (mac Bind_SwitchMA) ────────────────────────────────────────
    st, rec = setup('assist')
    Roles.saveBaseline()
    TH.assert_true(Roles.switchMA('Toon', 'tank', false, rec), 'switchMA me: applied')
    TH.assert_eq(st.session.role, 'tank', 'switchMA me tank: role tank')
    TH.assert_true(st.session.iAmMA, 'switchMA me: iAmMA')
    TH.assert_eq(st.session.mainAssist, 'Toon', 'switchMA me: mainAssist = me')
    TH.assert_eq(st.combat.assistAt, 100, 'switchMA me tank: checkRoles ran (assistAt 100)')
    TH.assert_eq(st.combat.calledTargetID, 0, 'switchMA: calledTargetID cleared')
    TH.assert_eq(calls.reset, 1, 'switchMA: combatReset')
    TH.assert_eq(#broadcasts, 0, 'switchMA broadcast=false: nothing sent')

    Roles.switchMA('Other', nil, false, rec)
    TH.assert_eq(st.session.role, 'assist', 'switchMA other: back to the original role')
    TH.assert_false(st.session.iAmMA, 'switchMA other: not the MA')
    TH.assert_eq(st.session.mainAssist, 'Other', 'switchMA other: mainAssist = Other')
    TH.assert_eq(st.combat.assistAt, 95, 'switchMA other: INI AssistAt restored')

    st, rec = setup('assist')
    Roles.saveBaseline()
    Roles.switchMA('toon', nil, true, rec)
    TH.assert_eq(st.session.role, 'tank', 'switchMA: role defaults to tank; name match ignores case')
    TH.assert_eq(#broadcasts, 1, 'switchMA broadcast=true: one broadcast')
    TH.assert_eq(broadcasts[1].t, 'SWITCHMA', 'broadcast type SWITCHMA')
    TH.assert_eq(broadcasts[1].d.newRole, 'tank', 'broadcast carries the role')

    st, rec = setup('assist')
    Roles.saveBaseline()
    MockMQ.set('TLO.Me.Pet.ID', 9)
    MockMQ.set('TLO.Me.Pet.CleanName', 'Fido')
    Roles.switchMA('fido', 'tank', false, rec)
    TH.assert_eq(st.session.role, 'pettank', 'switchMA my pet: role pettank')
    TH.assert_eq(st.session.mainAssist, 'Toon', 'switchMA my pet: mainAssist = me')
    TH.assert_eq(st.pet.assistAt, 100, 'switchMA my pet: pettank setup ran')

    st, rec = setup('assist')
    Roles.saveBaseline()
    Roles.switchMA('Other', 'tank', false, rec)
    TH.assert_eq(st.session.role, 'assist', 'switchMA other, role unchanged: stays assist')
    TH.assert_eq(st.combat.assistAt, 95, 'switchMA other, role unchanged: no checkRoles side effects')

    st, rec = setup('assist')
    TH.assert_false(Roles.switchMA('Toon', 'wizard', false, rec), 'switchMA unknown role → refused')
    TH.assert_eq(st.session.role, 'assist', 'switchMA unknown role: role unchanged')
    TH.assert_false(Roles.switchMA('', 'tank', false, rec), 'switchMA empty name → refused')
    TH.assert_false(Roles.switchMA('NULL', 'tank', false, rec), 'switchMA null name → refused')
    TH.assert_eq(calls.reset, 0, 'switchMA refused: no combatReset')

    -- ── UI Switch MA helpers (#346) ─────────────────────────────────────────
    local names, idx = Roles.maChoices({ me = 'Toon', members = { 'Toon', 'Tanky', 'Mercy' },
        pet = 'Petone', currentMA = 'Tanky' })
    TH.assert_eq(table.concat(names, ','), 'Toon,Tanky,Mercy,Petone', 'maChoices: me, members, pet; me not repeated')
    TH.assert_eq(idx, 2, 'maChoices: index of the current MA')

    names, idx = Roles.maChoices({ me = 'Toon', members = { 'tanky' }, pet = '', currentMA = 'TANKY' })
    TH.assert_eq(#names, 2, 'maChoices: no pet -> not listed')
    TH.assert_eq(idx, 2, 'maChoices: current MA matched case-insensitively')

    names, idx = Roles.maChoices({ me = 'Toon', members = {}, pet = '', currentMA = 'Raider' })
    TH.assert_eq(names[1], 'Raider', 'maChoices: MA outside the group listed first')
    TH.assert_eq(idx, 1, 'maChoices: ... and selected')

    names, idx = Roles.maChoices({ me = 'Toon', members = {}, pet = '', currentMA = '' })
    TH.assert_eq(#names, 1, 'maChoices: no MA -> just me')
    TH.assert_eq(idx, 1, 'maChoices: no MA -> first entry selected')

    TH.assert_eq(table.concat(Roles.switchMAWords('Tanky', 'tank', true), ' '), 'Tanky tank group',
        'switchMAWords: broadcast -> group')
    TH.assert_eq(table.concat(Roles.switchMAWords('Tanky', 'offtank', false), ' '), 'Tanky offtank',
        'switchMAWords: no broadcast -> no group')
    TH.assert_eq(Roles.MA_ROLE_CHOICES[1], 'tank', 'MA_ROLE_CHOICES: tank first (the bind default)')
    local allKnown = true
    for _, r in ipairs(Roles.MA_ROLE_CHOICES) do
        if not require('modules.config').ROLES[r] then allKnown = false end
    end
    TH.assert_true(allKnown, 'MA_ROLE_CHOICES: every entry is a role /switchma accepts')
end

return M
