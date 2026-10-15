-- luacheck config: run `luacheck .` from the repo root.
-- MQ2Lua runs LuaJIT (Lua 5.1 + goto).
std = "luajit"
max_line_length = false

-- Globals provided by MacroQuest's Lua runtime.
read_globals = {
    "mq",
    "printf",
    "ImGui",
    "ImGuiTableFlags",
    "ImGuiTableColumnFlags",
    "ImGuiWindowFlags",
    "ImVec2",
    "bit32", -- not stock LuaJIT (that's `bit`); MQ's runtime provides it
}

exclude_files = {
    "tests/mock_mq.lua",
}
