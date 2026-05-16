local mq     = require('mq')
local State  = require('modules.state')
local Utils  = require('modules.utils')
local Config = require('modules.config')

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

if State.session.mainAssist ~= '' then
    printf('\awMain Assist: \at%s \awAssist At: \at%d%%', State.session.mainAssist, State.session.assistAt)
end

-- Validate required plugins; continue even if some are missing (warn only)
Config.checkPlugins()

printf('\agKissAssist ready. \awEntering main loop.')

-- Main loop — mq.delay() processes events internally in MQ2Lua
while not State.terminate do
    mq.doevents()
    mq.delay(50)
end

printf('\ayKissAssist \aw%s stopped.', VERSION)
