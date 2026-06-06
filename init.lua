-- Route to the test runner when invoked as: /lua run kissassist-lua test
local args = {...}
if args[1] == 'test' then
    require('tests.run_tests')
    return
end

local mq     = require('mq')
local State  = require('modules.state')
local Utils  = require('modules.utils')
local Config = require('modules.config')
local Events = require('modules.events')
local Binds  = require('modules.binds')
local Cast   = require('modules.cast')
local Combat = require('modules.combat')
local Heal     = require('modules.healing')
local Buffs    = require('modules.buffs')
local Pet      = require('modules.pet')
local Bard     = require('modules.bard')
local Movement = require('modules.movement')
local Pull     = require('modules.pull')
local Loot     = require('modules.loot')
local Comms    = require('modules.comms')
local Cond     = require('modules.cond')
local Mez      = require('modules.mez')
local Debuff   = require('modules.debuff')
local Charm    = require('modules.charm')
local Afk      = require('modules.afk')
local Merc     = require('modules.merc')
local UI       = require('modules.ui')

local VERSION = '1.0.0'

-- Wire Utils debug flags to State.debug before any other output
Utils.init(State)

-- Parse CLI args first so debug flags are active for the rest of startup
Config.parseArgs(State, args)

printf('\agKissAssist \aw%s starting... Role: \at%s', VERSION, State.session.role)

-- Mirrors Sub AssignMainAssist (kissassist.mac): tank roles are their own MA.
-- Must run before Config.load so mainAssist is set when Combat.init reads it.
do
    local TANK_ROLES = {tank=true, pullertank=true, pettank=true, pullerpettank=true, hunterpettank=true}
    local myName = mq.TLO.Me.CleanName() or ''
    if TANK_ROLES[State.session.role] then
        State.session.iAmMA = true
        if State.session.mainAssist == '' then
            State.session.mainAssist = myName
        end
    else
        State.session.iAmMA = (State.session.mainAssist:lower() == myName:lower())
    end
end

-- Seed runtime identity from live TLO
State.session.iAmABard  = mq.TLO.Me.Class.ShortName() == 'BRD'
State.session.iAmARogue = mq.TLO.Me.Class.ShortName() == 'ROG'
local _CHARM_CLASSES = {DRU=true, ENC=true, NEC=true, BRD=true}
State.session.iAmACharmClass = _CHARM_CLASSES[mq.TLO.Me.Class.ShortName()] ~= nil
State.session.zoneName  = mq.TLO.Zone.ShortName()
local DMZ_ZONES = {[345]=true,[344]=true,[202]=true,[203]=true,[279]=true,[151]=true,[33506]=true}
State.misc.dmz = DMZ_ZONES[mq.TLO.Zone.ID()] ~= nil

-- Seed campZone at startup so pet, pull, AFK, and burn systems aren't blocked
-- before the user runs /makecamphere (mirrors .mac DeclareOuters behavior).
State.movement.campZone = mq.TLO.Zone.ID()

-- Load config (resolves INI filename; full migration in step 1.4b)
Config.load(State)

-- Load condition expressions from [KConditions] INI section
Cond.init(State, Utils)
Cond.load()

-- Wire loot settings from INI into State
State.loot.on       = tonumber(Config.get('General', 'LootOn',       '1')) or 1
State.loot.radius   = tonumber(Config.get('General', 'CorpseRadius', '100')) or 100
State.loot.spamInfo = tonumber(Config.get('General', 'SpamLootInfo', '1')) or 1

-- Wire cast gem settings from INI into State
State.cast.miscGem      = tonumber(Config.get('SpellSets', 'MiscGem',      '0')) or 0
State.cast.miscGemLW    = tonumber(Config.get('SpellSets', 'MiscGemLW',    '0')) or 0
State.cast.miscGemRemem = tonumber(Config.get('SpellSets', 'MiscGemRemem', '0')) or 0
State.cast.gemSlots     = 8 + (mq.TLO.Me.AltAbility('Mnemonic Retention').Rank() or 0)
-- Snapshot the spell currently occupying each misc gem slot (restored by CastReMem)
if State.cast.miscGem > 0 then
    State.cast.reMemMiscSpell = mq.TLO.Me.Gem(State.cast.miscGem).Name() or ''
end
if State.cast.miscGemLW > 0 then
    State.cast.reMemMiscSpellLW = mq.TLO.Me.Gem(State.cast.miscGemLW).Name() or ''
end

if State.session.mainAssist ~= '' then
    printf('\awMain Assist: \at%s \awAssist At: \at%d%%', State.session.mainAssist, State.session.assistAt)
end

-- Validate required plugins; continue even if some are missing (warn only)
Config.checkPlugins()

-- Register all game text events and in-game command binds
Events.register(State, Utils, Movement, Charm)
Cast.init(State, Utils)
Cast.setCond(Cond)
Heal.init(State, Utils, Cast, Cond, Movement, Comms)
Movement.init(State, Utils)
Comms.init(State, Utils)
Buffs.init(State, Utils, Cast, Heal, Comms, Cond)
Pet.init(State, Utils, Cast, Buffs, Movement)
Bard.init(State, Utils, Cast)
Cast.setBard(Bard)
Pull.init(State, Utils, Cast, Movement, Combat, Pet, Bard, Heal, Comms)
Loot.init(State, Utils)
Mez.init(State, Utils, Cast)
Debuff.init(State, Utils, Cast, Heal, Cond, Combat)
Charm.init(State, Utils, Cast, Pet, Bard, Comms)
Merc.init(State, Utils)
Combat.init(State, Utils, Cast, Heal, Movement, Bard, Cond, Mez, Debuff, Buffs, Comms, Merc, Charm)
Afk.init(State, Utils, Combat, Comms, Config)
Binds.register(State, Utils, Buffs, Loot, Cast, Combat, Config, Comms)
UI.init(State)

printf('\agKissAssist ready. \awEntering main loop.')

-- Expose live State globally so integration tests can access it via mq_eval:
--   require('tests.integration.test_debug_cmds').run(mq, KAState, TH)
_G.KAState = State

local PULLER_ROLES = {puller=true, pullertank=true, pullerpettank=true, hunter=true, hunterpettank=true}
if PULLER_ROLES[State.session.role] then
    printf('\ayCamp not set — run \at/makecamphere\ay before pulling.')
end

-- Main loop — phase order mirrors kissassist.mac Sub Main while(1) block (mac:360-456).
-- Verified against .mac source. Two intentional Lua additions: Comms.tick(), mq.delay(50).
-- Divergence from plan note: Buffs/Healing order was already correct; plan comment was stale.
while not State.terminate do
    -- Phase 1: events
    mq.doevents()
    -- Phase 1.5: AFK safety monitor (mac:375 / mac:414)
    if State.afk.on > 0 then Afk.check() end
    -- Phase 2: combat (first pass — mac:MainLoop1)
    if State.combat.dpsOn or State.combat.meleeOn then
        Combat.checkForCombat(0, 'main', 0)
    end
    -- Phase 2.5: corpse recovery (mac:369)
    if State.heal.corpsRecoveryOn == 1 then Heal.recoverCorpses() end
    -- Phase 3: heal / cure / rez
    Heal.writeDebuffs()
    Heal.checkCures()
    Heal.checkHealth('MainLoop')
    Buffs.castMount()  -- post-rez mount attempt (mac:6906/6968)
    -- Phase 3.5: charm
    if State.session.iAmACharmClass and State.charm.on then Charm.check('MainLoop') end
    -- Phase 4: movement
    if not State.combat.combatStart and State.movement.returnToCamp then
        Movement.doWeMove(0, 'mainloop')
    end
    if State.session.chaseAssist then Movement.doWeChase() end
    -- Phase 5: pet
    if State.pet.on and not State.combat.combatStart then Pet.doPetStuff() end
    if State.pet.on then Buffs.checkPetBuffs() end
    if State.pet.toysOn and State.buffs.kaPetBegActive then Buffs.checkBegforPetBuffs() end
    -- Phase 5.5: merc (mac:393)
    if State.merc.on > 0 then Merc.check() end
    -- Phase 6: buffs
    if not State.combat.combatStart and not State.session.danNetOn then
        Buffs.writeBuffs()
        Buffs.writeBuffsPet()
        Buffs.writeBuffsMerc()
    end
    if State.buffs.buffsOn then
        Buffs.castMana()  -- mana restore before full buff cycle (mac:394 MainLoop)
        Buffs.checkBuffs(State.buffs.forceBuffs)
        State.buffs.forceBuffs = false
    end
    if State.buffs.kaBegActive then Buffs.checkBegforBuffs() end
    -- Phase 7: bard
    if State.session.iAmABard then Bard.doBardStuff() end
    -- Phase 8: med (only out of combat — mac:409-410)
    Heal.doWeMed()
    -- Phase 9: pull
    local campSet = (State.movement.campX ~= 0 or State.movement.campY ~= 0)
    if PULLER_ROLES[State.session.role] and campSet then
        if not State.pull.hold then
            if State.pull.mob == 0 then Pull.findMobToPull(1, 1, 0) end
            if State.pull.mob ~= 0 then Pull.pullCheck() end
            State.pull.mob = 0
        end
    end
    -- Phase 10: combat (second pass — mac:MainLoop2, 200ms wait catches post-buff aggro)
    if State.combat.dpsOn or State.combat.meleeOn then
        Combat.checkForCombat(0, 'main2', 200)
    else
        Combat.checkForCombat(1, 'main3', 0)
    end
    -- Phase 11: loot
    if State.loot.on == 1 and not State.combat.combatStart then Loot.tick() end
    -- Phase 12: comms (Lua addition — no .mac equivalent)
    Comms.tick()
    mq.delay(50)
end

Events.unregister()
Binds.unregister()
printf('\ayKissAssist \aw%s stopped.', VERSION)
