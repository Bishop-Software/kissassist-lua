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

local VERSION = '1.0.0'

-- Collect CLI args passed after /lua run kissassist-lua
local args = {...}

-- Wire Utils debug flags to State.debug before any other output
Utils.init(State)

-- Parse CLI args first so debug flags are active for the rest of startup
Config.parseArgs(State, args)

printf('\agKissAssist \aw%s starting... Role: \at%s', VERSION, State.session.role)

-- Seed camp location and runtime identity from live TLO
State.movement.campX   = mq.TLO.Me.X()
State.movement.campY   = mq.TLO.Me.Y()
State.movement.campZ   = mq.TLO.Me.Z()
State.movement.campZone = mq.TLO.Zone.ID()
State.session.iAmABard  = mq.TLO.Me.Class.ShortName() == 'BRD'
State.session.zoneName  = mq.TLO.Zone.ShortName()
local DMZ_ZONES = {[345]=true,[344]=true,[202]=true,[203]=true,[279]=true,[151]=true,[33506]=true}
State.misc.dmz = DMZ_ZONES[mq.TLO.Zone.ID()] == true

-- Load config (resolves INI filename; full migration in step 1.4b)
Config.load(State)

-- Wire cast gem settings from INI into State
State.cast.miscGem      = tonumber(Config.get('SpellS', 'MiscGem',      '0')) or 0
State.cast.miscGemLW    = tonumber(Config.get('SpellS', 'MiscGemLW',    '0')) or 0
State.cast.miscGemRemem = tonumber(Config.get('SpellS', 'MiscGemRemem', '0')) or 0
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
Events.register(State, Utils, Movement)
Binds.register(State, Utils, Buffs)
Cast.init(State, Utils)
Heal.init(State, Utils, Cast)
Movement.init(State, Utils)
Combat.init(State, Utils, Cast, Heal, Movement, Bard)
Buffs.init(State, Utils, Cast, Heal)
Pet.init(State, Utils, Cast, Buffs, Movement)
Bard.init(State, Utils, Cast)
Cast.setBard(Bard)
Pull.init(State, Utils, Cast, Movement, Combat, Pet, Bard)

printf('\agKissAssist ready. \awEntering main loop.')

local PULLER_ROLES = {puller=true, pullertank=true, pullerpettank=true, hunter=true, hunterpettank=true}

-- Main loop — mq.delay() processes events internally in MQ2Lua
while not State.terminate do
    mq.doevents()
    if State.combat.dpsOn or State.combat.meleeOn then
        Combat.checkForCombat(0, 'main', 0)
    end
    if not State.combat.combatStart and not State.session.danNetOn then
        Buffs.writeBuffs()
        Buffs.writeBuffsPet()
        Buffs.writeBuffsMerc()
    end
    if State.buffs.buffsOn then
        Buffs.checkBuffs(State.buffs.forceBuffs)
        State.buffs.forceBuffs = false
    end
    if State.buffs.kaBegActive then Buffs.checkBegforBuffs() end
    if State.pet.on then Buffs.checkPetBuffs() end
    if State.pet.toysOn and State.buffs.kaPetBegActive then Buffs.checkBegforPetBuffs() end
    if State.pet.on and not State.combat.combatStart then Pet.doPetStuff() end
    Heal.writeDebuffs()
    Heal.checkHealth('MainLoop')
    Heal.checkCures()
    Heal.doWeMed()
    if State.session.iAmABard then Bard.doBardStuff() end
    if not State.combat.combatStart and State.movement.returnToCamp then
        Movement.doWeMove(0, 'mainloop')
    end
    if State.session.chaseAssist then Movement.doWeChase() end
    if PULLER_ROLES[State.session.role] then
        if not State.pull.hold then
            if State.pull.mob == 0 then Pull.findMobToPull(1, 1, 0) end
            if State.pull.mob ~= 0 then Pull.pullCheck() end
            State.pull.mob = 0
        end
    end
    mq.delay(50)
end

Events.unregister()
Binds.unregister()
printf('\ayKissAssist \aw%s stopped.', VERSION)
