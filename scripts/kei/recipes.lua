local KEI_ROTOR_FILTER = "KEI_ROTOR"
local KEI_PROTOCOL_FILTER = "KEI_PROTOCOL"
local KEI_POWER_FILTER = "KEI_POWER"
local CombatProtocolDefs = require("kei/protocols/combat")
local GrowthRecipes = require("kei/growth_recipes")
local RotorUpgrades = require("kei/drone/upgrades")
local ROTOR_ICON = "kei_drone_zap_remote_close.tex"
local ROTOR_ATLAS = "images/inventoryimages/kei_items.xml"

AddRecipeFilter({
    name = KEI_ROTOR_FILTER,
    atlas = ROTOR_ATLAS,
    image = ROTOR_ICON,
    image_size = 64,
})
STRINGS.UI.CRAFTING_FILTERS[KEI_ROTOR_FILTER] = "无人机"

local PROTOCOL_ICON = "kei_blank_cd.tex"
local PROTOCOL_ATLAS = "images/inventoryimages/kei_items.xml"

local function GetRecipeImage(image_name)
    if image_name == nil then
        return PROTOCOL_ICON
    end
    return image_name:match("%.tex$") ~= nil
        and image_name
        or image_name .. ".tex"
end

AddRecipeFilter({
    name = KEI_PROTOCOL_FILTER,
    atlas = PROTOCOL_ATLAS,
    image = PROTOCOL_ICON,
    image_size = 64,
})
STRINGS.UI.CRAFTING_FILTERS[KEI_PROTOCOL_FILTER] = "协议"

local POWER_ICON = "kei_dev_generator.tex"
local POWER_ATLAS = "images/inventoryimages/kei_items_ir.xml"

AddRecipeFilter({
    name = KEI_POWER_FILTER,
    atlas = POWER_ATLAS,
    image = POWER_ICON,
    image_size = 64,
})
STRINGS.UI.CRAFTING_FILTERS[KEI_POWER_FILTER] = "电力"

local function image(tex)
    -- AddRecipe2 需要 atlas + image 成对传入。
    return {
        atlas = GetInventoryItemAtlas(tex),
        image = tex,
    }
end

local function kei_config(tex, extra)
    -- 未显式指定图标的配方仍回退到通用 Kei 分类图标。
    local cfg
    if type(tex) == "table" then
        -- 如果第一个参数是 table，说明传入了完整的配置
        cfg = tex
    else
        -- 否则，使用传统的 tex + extra 方式
        cfg = image(tex or "wagstaff_item_2.tex")
        if extra ~= nil then
            for k, v in pairs(extra) do
                cfg[k] = v
            end
        end
    end

    -- AddCharacterRecipe 的配置经常只包含 product/nameoverride，必须给
    -- 没有专用图标的配方补充合法的原版金块图标。
    if cfg.atlas == nil or cfg.image == nil then
        cfg.atlas = cfg.atlas or GetInventoryItemAtlas("goldnugget.tex") or "images/inventoryimages1.xml"
        cfg.image = cfg.image or "goldnugget.tex"
    end
    cfg.builder_tag = "kei"
    return cfg
end

local function experience_ingredient(recname)
    -- The private marker supplies dynamic experience costs for this recipe.
    local ingredient = Ingredient(
        CHARACTER_INGREDIENT.KEI_EXPERIENCE,
        5,
        "images/inventoryimages/kei_exp.xml",
        nil,
        "kei_exp.tex"
    )
    ingredient.kei_growth_recipe = recname
    return ingredient
end

local function fixed_experience_ingredient(amount)
    -- The marker stores the fixed cost while the ingredient remains a
    -- dedicated character-resource type.
    local ingredient = Ingredient(
        CHARACTER_INGREDIENT.KEI_EXPERIENCE,
        5,
        "images/inventoryimages/kei_exp.xml",
        nil,
        "kei_exp.tex"
    )
    ingredient.kei_experience_cost = amount
    return ingredient
end

-- 普通 Kei 配方归入冒险家（角色）栏；无人机配方只归入无人机栏。
local filters = { "CHARACTER" }
local rotor_filters = { KEI_ROTOR_FILTER }
local protocol_filters = { KEI_PROTOCOL_FILTER }
local power_filters = { KEI_POWER_FILTER }

local function AddPowerRecipe(name, ingredients, image_name)
    AddRecipe2(
        name,
        ingredients,
        TECH.NONE,
        kei_config({
            atlas = "images/inventoryimages/kei_items_ir.xml",
            image = image_name .. ".tex",
            product = name,
            nounlock = true,
        }),
        power_filters
    )
end

AddPowerRecipe("kei_dev_generator_item", { Ingredient("gears", 2), Ingredient("transistor", 2) }, "kei_dev_generator")
AddPowerRecipe("kei_batterysm_item", { Ingredient("goldnugget", 2), Ingredient("transistor", 1) }, "kei_batterysm")
AddPowerRecipe("kei_electrobank", { Ingredient("goldnugget", 2), Ingredient("transistor", 1) }, "kei_electrobank")
AddPowerRecipe("kei_electrobank_charger_small_item", { Ingredient("goldnugget", 2), Ingredient("transistor", 2) }, "kei_electrobank_charger_small")
AddPowerRecipe("kei_research_center_item", { Ingredient("goldnugget", 1) }, "kei_research_center")
AddPowerRecipe("kei_research_center2_item", { Ingredient("goldnugget", 1) }, "kei_research_center2")
AddPowerRecipe("kei_material_research_centre_item", { Ingredient("goldnugget", 1) }, "kei_material_research_centre")
AddPowerRecipe("kei_utilities_electric_item", { Ingredient("twigs", 2), Ingredient("transistor", 1) }, "kei_utilities_electric")
AddPowerRecipe("kei_utilities_electric_conduct_item", { Ingredient("goldnugget", 1), Ingredient("transistor", 1) }, "kei_utilities_electric_conduct")
AddPowerRecipe("kei_utilities_electric_conduct_hiwatt_item", { Ingredient("goldnugget", 2), Ingredient("transistor", 2) }, "kei_utilities_electric_conduct_hiwatt")
AddPowerRecipe("kei_logic_wires_item", { Ingredient("twigs", 2), Ingredient("transistor", 1) }, "kei_logic_wires")

-- 空白 CD 和可直接制作的协议 CD 统一放在协议栏。
AddRecipe2(
    "kei_blank_cd",
    { fixed_experience_ingredient(1000) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_items.xml",
        image = "kei_blank_cd.tex",
    }),
    protocol_filters
)

local function IsDirectlyCraftableProtocol(def)
    return def ~= nil
        and def.prefab ~= nil
        and def.category == "beast"
        and def.tier == "basic"
end

-- 初级巨兽协议使用对应战利品和 1 个空白 CD 制作。
-- 材料以协议 ID 维护，避免把配方名和材料名耦合在一起。
local BASIC_BEAST_PROTOCOL_INGREDIENTS = {
    deerclops_basic = {
        { prefab = "deerclops_eyeball", amount = 1 },
    },
    bearger_basic = {
        { prefab = "bearger_fur", amount = 1 },
    },
    moose_basic = {
        { prefab = "goose_feather", amount = 6 },
    },
    antlion_basic = {
        { prefab = "townportaltalisman", amount = 10 },
    },
    eyeofterror_basic = {
        { prefab = "eyemaskhat", amount = 1 },
    },
    daywalker_basic = {
        { prefab = "dreadstonehat", amount = 1 },
        { prefab = "armordreadstone", amount = 1 },
    },
    daywalker2_basic = {
        { prefab = "wagpunkbits_kit", amount = 1 },
        { prefab = "scraphat", amount = 1 },
    },
    lordfruitfly_basic = {
        { prefab = "fruitflyfruit", amount = 1 },
    },
    minotaur_basic = {
        { prefab = "minotaurhorn", amount = 1 },
    },
    vault_pillar_guard_basic = {
        { prefab = "vault_pillar_guard_piece_1", amount = 1 },
        { prefab = "vault_pillar_guard_piece_2", amount = 1 },
        { prefab = "vault_pillar_guard_piece_3", amount = 1 },
    },
    dragonfly_basic = {
        { prefab = "dragon_scales", amount = 2 },
    },
    malbatross_basic = {
        { prefab = "malbatross_beak", amount = 1 },
    },
    klaus_basic = {
        { prefab = "klaussackkey", amount = 1 },
    },
    toadstool_basic = {
        { prefab = "shroom_skin", amount = 3 },
    },
    beequeen_basic = {
        { prefab = "hivehat", amount = 1 },
        { prefab = "royal_jelly", amount = 2 },
    },
    stalker_atrium_basic = {
        { prefab = "skeletonhat", amount = 1 },
        { prefab = "armorskeleton", amount = 1 },
    },
    alterguardian_basic = {
        { prefab = "alterguardianhat", amount = 1 },
    },
}

local function GetProtocolIngredients(def)
    local ingredients = BASIC_BEAST_PROTOCOL_INGREDIENTS[def.protocol]
    if def.category == "beast" and def.tier == "basic" then
        assert(ingredients ~= nil, "Missing ingredients for basic beast protocol: " .. tostring(def.protocol))
    end
    if ingredients == nil then
        return { Ingredient("goldnugget", 1) }
    end

    local recipe_ingredients = {
        Ingredient("kei_blank_cd", 1, PROTOCOL_ATLAS, nil, PROTOCOL_ICON),
    }
    for _, ingredient in ipairs(ingredients) do
        table.insert(recipe_ingredients, Ingredient(ingredient.prefab, ingredient.amount))
    end
    return recipe_ingredients
end

-- 使用协议定义自动生成初级巨兽配方，新增初级巨兽协议时无需重复维护配方列表。
for _, def in ipairs(CombatProtocolDefs.COMBAT_PROTOCOL_LIST) do
    if IsDirectlyCraftableProtocol(def) then
        local recipe_name = def.prefab
        local visual = CombatProtocolDefs.GetProtocolVisual(def.protocol)
        STRINGS.RECIPE_DESC[string.upper(recipe_name)] = "使用指定材料和 1 个空白 CD 制作该协议 CD。"
        AddRecipe2(
            recipe_name,
            GetProtocolIngredients(def),
            TECH.NONE,
            kei_config({
                atlas = visual ~= nil and visual.atlas or PROTOCOL_ATLAS,
                image = GetRecipeImage(visual ~= nil and visual.image or nil),
                product = def.prefab,
            }),
            protocol_filters
        )
    end
end

-- 数据记录仪部署包：部署后创建场景中的记录仪结构。
AddRecipe2(
    "kei_data_recorder_item",
    { Ingredient("transistor", 2), Ingredient("gears", 1) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_items.xml",
        image = "kei_data_recorder_item.tex",
    }),
    filters
)

-- 修理工具：恢复机体完整度，一次配方给多份便于测试。
AddRecipe2(
    "kei_repair_tool",
    { Ingredient("gears", 1), Ingredient("transistor", 1), Ingredient("butter", 1) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_items.xml",
        image = "kei_repair_tool.tex",
        numtogive = 3,
    }),
    filters
)

-- 装备解析工具：把装备属性转换为解析协议 CD。
AddRecipe2(
    "kei_analysis_tool",
    { fixed_experience_ingredient(1000) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_items.xml",
        image = "kei_analysis_tool.tex",
    }),
    filters
)

-- Life protocol CDs unlocked by Hermit Crab friendship.
AddRecipe2(
    "kei_life_cd_durability_restore",
    {
        Ingredient("sewing_kit", 1),
        Ingredient("sewing_tape", 3),
        Ingredient("greenamulet", 1),
    },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_life_cd_item.xml",
        image = "kei_life_cd.tex",
        product = "kei_life_cd_durability_restore",
        nounlock = true,
    }),
    filters
)

AddRecipe2(
    "kei_life_cd_map_teleport",
    {
        Ingredient("telestaff", 1),
        Ingredient("orangestaff", 1),
    },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_life_cd_item.xml",
        image = "kei_life_cd.tex",
        product = "kei_life_cd_map_teleport",
        nounlock = true,
    }),
    filters
)

-- Rotor surveyor controller recipe.
AddRecipe2(
    "kei_rotor_surveyor",
    { fixed_experience_ingredient(100) },
    TECH.NONE,
    kei_config({
        atlas = ROTOR_ATLAS,
        image = ROTOR_ICON,
        product = "kei_rotor_survey_controller",
    }),
    rotor_filters
)

-- 无人机技能解锁：每项技能独立消耗 1000 点当前经验，制作后永久解锁。
local rotor_skill_recipes = {
    { name = "kei_rotor_skill_pilot", label = "无人机技能  驾驶" },
    { name = "kei_rotor_skill_resurrection", label = "无人机技能  苏生光束" },
    { name = "kei_rotor_skill_heal", label = "无人机技能  治愈光束" },
    { name = "kei_rotor_skill_strengthen", label = "无人机技能  强化光束" },
    { name = "kei_rotor_skill_confinement", label = "无人机技能  禁锢光束" },
    { name = "kei_rotor_skill_dead", label = "无人机技能  死亡光束" },
    { name = "kei_rotor_skill_survey", label = "无人机技能  调查光束" },
    { name = "kei_rotor_skill_follow", label = "无人机技能  跟随" },
    { name = "kei_rotor_skill_teleport", label = "无人机技能  传送光束" },
    { name = "kei_rotor_skill_collect", label = "无人机技能  收集光束" },
    { name = "kei_rotor_skill_fishing", label = "无人机技能  捕捞光束" },
    { name = "kei_rotor_skill_nature", label = "无人机技能  自然光束" },
    { name = "kei_rotor_skill_friendly", label = "无人机技能  友善光束" },
}

for _, data in ipairs(rotor_skill_recipes) do
    AddRecipe2(
        data.name,
        { fixed_experience_ingredient(1000) },
        TECH.NONE,
        kei_config({
            atlas = ROTOR_ATLAS,
            image = ROTOR_ICON,
            product = data.name,
            nounlock = true,
            canbuild = GrowthRecipes.CanBuildRotorSkill,
            getlimitedrecipecount = GrowthRecipes.GetRotorSkillRecipeCount,
        }),
        rotor_filters
    )
end

local rotor_upgrade_recipes = {
    { name = "kei_rotor_upgrade_signal", label = "Signal Enhancement", experience = 500 },
    { name = "kei_rotor_upgrade_mobility", label = "Power Enhancement", experience = 300 },
    { name = "kei_rotor_upgrade_battery", label = "Battery Expansion", experience = 150 },
    { name = "kei_rotor_upgrade_power_reduction", label = "Power Saving" },
}

for _, data in ipairs(rotor_upgrade_recipes) do
    local upgrade = RotorUpgrades.GetUpgradeForRecipe(data.name)
    AddRecipe2(
        data.name,
        { fixed_experience_ingredient(
            RotorUpgrades.GetExperienceCost(upgrade)
                or data.experience
                or TUNING.KEI_ROTOR_UPGRADE_EXPERIENCE_COST
                or 1000
        ) },
        TECH.NONE,
        kei_config({
            atlas = ROTOR_ATLAS,
            image = ROTOR_ICON,
            product = data.name,
            nounlock = true,
            canbuild = GrowthRecipes.CanBuildRotorUpgrade,
            getlimitedrecipecount = GrowthRecipes.GetRotorUpgradeRecipeCount,
        }),
        rotor_filters
    )
end

-- 协议预设盒：保存一组协议 CD，并可与当前已解锁协议槽一键交换。
AddRecipe2(
    "kei_protocol_binder",
    { Ingredient("boards", 2), Ingredient("transistor", 2) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_protocol_binder.xml",
        image = "kei_protocol_binder.tex",
    }),
    filters
)

-- 唤鱼魔法：大霜鲨生活协议插入时临时解锁；制作时直接施法，不生成物品。
AddRecipe2(
    "kei_fish_call_spell",
    { fixed_experience_ingredient(TUNING.KEI_LIFE_FISH_CALL_EXPERIENCE_COST or 50) },
    TECH.LOST,
    kei_config({
        atlas = GetInventoryItemAtlas("book_fish.tex"),
        image = "book_fish.tex",
        product = "kei_fish_call_spell",
        nounlock = true,
    }),
    filters
)
-- 满月魔法：满月生活协议插入时临时解锁；制作时直接施法，不生成物品。
AddRecipe2(
    "kei_fullmoon_spell",
    { fixed_experience_ingredient(TUNING.KEI_LIFE_FULLMOON_EXPERIENCE_COST or 100) },
    TECH.LOST,
    kei_config({
        atlas = GetInventoryItemAtlas("book_moon.tex"),
        image = "book_moon.tex",
        product = "kei_fullmoon_spell",
        nounlock = true,
    }),
    filters
)
-- 新月魔法：新月生活协议插入时临时解锁；制作时直接施法，不生成物品。
AddRecipe2(
    "kei_newmoon_spell",
    { fixed_experience_ingredient(TUNING.KEI_LIFE_NEWMOON_EXPERIENCE_COST or 100) },
    TECH.LOST,
    kei_config({
        atlas = GetInventoryItemAtlas("book_moon.tex"),
        image = "book_moon.tex",
        product = "kei_newmoon_spell",
        nounlock = true,
    }),
    filters
)
-- 催熟魔法：催熟生活协议插入时临时解锁；制作时直接施法，不生成物品。
AddRecipe2(
    "kei_ripen_spell",
    { fixed_experience_ingredient(TUNING.KEI_LIFE_RIPEN_EXPERIENCE_COST or 50) },
    TECH.LOST,
    kei_config({
        atlas = GetInventoryItemAtlas("book_horticulture_upgraded.tex"),
        image = "book_horticulture_upgraded.tex",
        product = "kei_ripen_spell",
        nounlock = true,
    }),
    filters
)

-- 晴雨魔法：晴雨生活协议插入时临时解锁；制作时直接切换晴天与降水，不生成物品。
AddRecipe2(
    "kei_weather_spell",
    { fixed_experience_ingredient(TUNING.KEI_LIFE_WEATHER_EXPERIENCE_COST or 50) },
    TECH.LOST,
    kei_config({
        atlas = GetInventoryItemAtlas("book_rain.tex"),
        image = "book_rain.tex",
        product = "kei_weather_spell",
        nounlock = true,
    }),
    filters
)
-- Kei can build Winona's portable engineering chain without inheriting Winona's tags.
local winona_recipes = {
    {
        name = "kei_sewing_tape",
        ingredients = { Ingredient("silk", 1), Ingredient("cutgrass", 3) },
        tech = TECH.NONE,
        config = {
            atlas = GetInventoryItemAtlas("sewing_tape.tex"),
            image = "sewing_tape.tex",
            product = "sewing_tape",
            nameoverride = "sewing_tape",
            description = "sewing_tape",
        },
    },
    {
        name = "kei_winona_catapult_item",
        ingredients = { Ingredient("sewing_tape", 1), Ingredient("twigs", 3), Ingredient("rocks", 15) },
        tech = TECH.NONE,
        config = {
            atlas = GetInventoryItemAtlas("winona_catapult.tex"),
            image = "winona_catapult.tex",
            product = "winona_catapult_item",
            nameoverride = "winona_catapult",
            description = "winona_catapult",
        },
    },
    {
        name = "kei_winona_spotlight_item",
        ingredients = { Ingredient("sewing_tape", 1), Ingredient("goldnugget", 2), Ingredient("fireflies", 1) },
        tech = TECH.NONE,
        config = {
            atlas = GetInventoryItemAtlas("winona_spotlight.tex"),
            image = "winona_spotlight.tex",
            product = "winona_spotlight_item",
            nameoverride = "winona_spotlight",
            description = "winona_spotlight",
        },
    },
    {
        name = "kei_winona_battery_low_item",
        ingredients = { Ingredient("sewing_tape", 1), Ingredient("log", 2), Ingredient("nitre", 2) },
        tech = TECH.NONE,
        config = {
            atlas = GetInventoryItemAtlas("winona_battery_low.tex"),
            image = "winona_battery_low.tex",
            product = "winona_battery_low_item",
            nameoverride = "winona_battery_low",
            description = "winona_battery_low",
        },
    },
    {
        name = "kei_winona_battery_high_item",
        ingredients = { Ingredient("sewing_tape", 1), Ingredient("boards", 2), Ingredient("transistor", 2) },
        tech = TECH.NONE,
        config = {
            atlas = GetInventoryItemAtlas("winona_battery_high.tex"),
            image = "winona_battery_high.tex",
            product = "winona_battery_high_item",
            nameoverride = "winona_battery_high",
            description = "winona_battery_high",
        },
    },
    {
        name = "kei_winona_storage_robot",
        ingredients = { Ingredient("wagpunk_bits", 8), Ingredient("transistor", 4) },
        tech = TECH.NONE,
        config = {
            atlas = GetInventoryItemAtlas("winona_storage_robot.tex"),
            image = "winona_storage_robot.tex",
            product = "winona_storage_robot",
            nameoverride = "winona_storage_robot",
            description = "winona_storage_robot",
        },
    },
    {
        name = "kei_winona_remote",
        ingredients = { Ingredient("transistor", 1) },
        tech = TECH.NONE,
        config = {
            atlas = GetInventoryItemAtlas("winona_remote.tex"),
            image = "winona_remote.tex",
            product = "winona_remote",
            nameoverride = "winona_remote",
            description = "winona_remote",
        },
    },
}

for _, data in ipairs(winona_recipes) do
    AddCharacterRecipe(
        data.name,
        data.ingredients,
        data.tech,
        kei_config(data.config),
        filters
    )
end

-- Growth recipes consume the current full experience value.
AddRecipe2(
    GrowthRecipes.SLOT_UNLOCK_RECIPE,
    { experience_ingredient(GrowthRecipes.SLOT_UNLOCK_RECIPE) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_protocol_slot_states.xml",
        image = "kei_protocol_slot_openable.tex",
        product = GrowthRecipes.SLOT_UNLOCK_RECIPE,
        nounlock = true,
        canbuild = GrowthRecipes.CanBuildSlotUnlock,
    }),
    filters
)

AddRecipe2(
    GrowthRecipes.DEEP_IMPLANT_RECIPE,
    { experience_ingredient(GrowthRecipes.DEEP_IMPLANT_RECIPE) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_implant.xml",
        image = "kei_implant.tex",
        product = GrowthRecipes.DEEP_IMPLANT_RECIPE,
        nounlock = true,
        canbuild = GrowthRecipes.CanBuildDeepImplant,
    }),
    filters
)

AddRecipe2(
    GrowthRecipes.POTENTIAL_RECIPE,
    { experience_ingredient(GrowthRecipes.POTENTIAL_RECIPE) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_potential.xml",
        image = "kei_potential.tex",
        product = GrowthRecipes.POTENTIAL_RECIPE,
        nounlock = true,
        canbuild = GrowthRecipes.CanBuildPotential,
    }),
    filters
)

AddRecipe2(
    GrowthRecipes.MINI_ALICE_PAGE_RECIPE,
    { experience_ingredient(GrowthRecipes.MINI_ALICE_PAGE_RECIPE) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_alice_slot.xml",
        image = "kei_alice_slot.tex",
        product = GrowthRecipes.MINI_ALICE_PAGE_RECIPE,
        nounlock = true,
        canbuild = GrowthRecipes.CanBuildMiniAlicePage,
        getlimitedrecipecount = GrowthRecipes.GetMiniAlicePageRecipeCount,
    }),
    filters
)

AddRecipe2(
    GrowthRecipes.ANALYSIS_ARMOR_UPGRADE_RECIPE,
    { experience_ingredient(GrowthRecipes.ANALYSIS_ARMOR_UPGRADE_RECIPE) },
    TECH.NONE,
    kei_config({
        atlas = "images/inventoryimages/kei_items.xml",
        image = "kei_analysis_cd.tex",
        product = GrowthRecipes.ANALYSIS_ARMOR_UPGRADE_RECIPE,
        nounlock = true,
        canbuild = GrowthRecipes.CanBuildAnalysisArmorUpgrade,
        getlimitedrecipecount = GrowthRecipes.GetAnalysisArmorUpgradeRecipeCount,
    }),
    filters
)

-- 无用 CD 回收：不消耗经验或其他材料，直接回收第一格协议槽中的
-- 支持类型 CD，并按协议类别返还当前经验。
AddRecipe2(
    GrowthRecipes.PROTOCOL_CD_RECYCLE_RECIPE,
    { fixed_experience_ingredient(0) },
    TECH.NONE,
    kei_config({
        atlas = PROTOCOL_ATLAS,
        image = PROTOCOL_ICON,
        product = GrowthRecipes.PROTOCOL_CD_RECYCLE_RECIPE,
        nounlock = true,
        canbuild = GrowthRecipes.CanBuildProtocolCDRecycle,
    }),
    filters
)
