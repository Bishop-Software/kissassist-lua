-- tests/unit/test_ui_api.lua
-- The GUI uses the control API only (kactl design #360, phase 3c #363): no file
-- in modules/ui/ writes the config itself (Config.set / Config.save) or sends a
-- slash command, except a plugin's own commands (MQ2Medley's /medley). Settings
-- go through Control.set, lists through Control.setEntries, buttons through
-- Control.run / Control.defer.
local M = {}

-- Every file in modules/ui/. A new one must be added here to be scanned.
M.FILES = {
    'bard', 'cc', 'combat', 'healing', 'helpers', 'pull', 'settings', 'spells',
    'status', 'support',
}

-- Commands the GUI may send: plugin commands, not kissassist ones.
M.ALLOWED_COMMANDS = { ['/medley'] = true }

-- Code with comments removed (block comments, then line comments).
local function stripComments(text)
    text = text:gsub('%-%-%[(=*)%[.-%]%1%]', '')
    return (text:gsub('%-%-[^\n]*', ''))
end

-- Violations in one file's source: a list of 'line N: what'.
function M.scan(text)
    local found = {}
    local n = 0
    for line in (stripComments(text) .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if line:find('Config%.set%s*%(') or line:find('Config%.save%s*%(') then
            found[#found + 1] = string.format('line %d: writes the config: %s', n, line:match('^%s*(.-)%s*$'))
        end
        for args in line:gmatch('mq%.cmdf?%s*(%b())') do
            local cmd = args:match('^%(%s*[\'"](/[%w_]+)')
            if not (cmd and M.ALLOWED_COMMANDS[cmd:lower()]) then
                found[#found + 1] = string.format('line %d: sends a command: mq.cmd%s', n, args)
            end
        end
    end
    return found
end

function M.run(TH, _MockMQ)
    TH.setSuite('test_ui_api')

    -- The scanner itself
    TH.assert_eq(#M.scan("Config.set('Melee', 'MeleeOn', '1')"), 1, 'scan: Config.set flagged')
    TH.assert_eq(#M.scan('Config.save()'), 1, 'scan: Config.save flagged')
    TH.assert_eq(#M.scan("mq.cmd('/kactl burn')"), 1, 'scan: a kissassist command flagged')
    TH.assert_eq(#M.scan("mq.cmdf('/togglevariable %s on', x)"), 1, 'scan: cmdf flagged')
    TH.assert_eq(#M.scan('mq.cmd(line)'), 1, 'scan: a command built at run time flagged')
    TH.assert_eq(#M.scan("mq.cmdf('/medley %s', set)"), 0, 'scan: /medley (plugin) allowed')
    TH.assert_eq(#M.scan("-- Config.set('A', 'B', 1)\nlocal x = 1"), 0, 'scan: comments ignored')
    TH.assert_eq(#M.scan("Control.set('MeleeOn', true)"), 0, 'scan: Control.set allowed')
    TH.assert_eq(#M.scan("local v = Config.get('DPS', 'DPS', nil)"), 0, 'scan: Config.get allowed')

    -- Every GUI file
    for _, name in ipairs(M.FILES) do
        local path = package.searchpath('modules.ui.' .. name, package.path)
        TH.assert_not_nil(path, 'found modules/ui/' .. name .. '.lua')
        if path then
            local f = io.open(path, 'r')
            local text = f and f:read('*a') or ''
            if f then f:close() end
            local found = M.scan(text)
            TH.assert_eq(#found, 0, string.format('modules/ui/%s.lua uses the control API only%s',
                name, #found > 0 and (': ' .. table.concat(found, '; ')) or ''))
        end
    end
end

return M
