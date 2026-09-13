-- 通用组件和实体钩子。保持这里的顺序，便于阅读和定位注册逻辑。

local HOOKS = {
    "playerhearing",
    "wanderingtrader_map",
    "dormant",
    "containers",
    "combat",
    "storm",
    "miasma",
    "inventory",
    "inventorybar",
    "craftingmenu",
    "itemtile",
    "experience",
    "hermitcrab",
    "task_targets",
    "network",
}

for _, name in ipairs(HOOKS) do
    modimport("scripts/kei/hooks/" .. name .. ".lua")
end
