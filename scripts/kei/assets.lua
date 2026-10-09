-- 模组资源统一清单。

Assets = {
    Asset("ATLAS", "images/quagmire_recipebook.xml"),
    Asset("IMAGE", "images/quagmire_recipebook.tex"),
    Asset("SOUNDPACKAGE", "sound/tendou_kei_vc.fev"),
    Asset("SOUND", "sound/tendou_kei_vc.fsb"),
    Asset("SOUNDPACKAGE", "sound/kei_hit_sound.fev"),
    Asset("SOUND", "sound/kei_hit_sound.fsb"),
    Asset("SOUNDPACKAGE", "sound/kei_carol_a01.fev"),
    Asset("SOUND", "sound/kei_carol_a01.fsb"),
}

local ANIM_ASSETS = {
    "anim/kei_exp.zip",
    "anim/kei.zip",
    "anim/ghost_kei_build.zip",
    "anim/kei_items.zip",
    "anim/kei_life_cd.zip",
    "anim/kei_biome_cd.zip",
    "anim/kei_beast_purple_cd.zip",
    "anim/kei_beast_golden_cd.zip",
    "anim/kei_data_recorder.zip",
    "anim/kei_protocol_binder.zip",
    "anim/kei_protocol_popup.zip",
    "anim/ui_kei_protocol_box_7x1.zip",
    "anim/ui_kei_mini_alice_box_8x1.zip",
    "anim/wx_chassis.zip",
    "anim/kei_status_power.zip",
    "anim/kei_status_stability.zip",
    "anim/kei_status_integrity.zip",
    "anim/kei_status_power_meter.zip",
    "anim/kei_status_stability_meter.zip",
    "anim/kei_status_integrity_meter.zip",
    "anim/status_meter_wx_shield.zip",
    "anim/kei_dev_generator.zip",
    "anim/kei_batterysm.zip",
    "anim/kei_electrobank.zip",
    "anim/kei_electrobank_charger_small.zip",
    "anim/kei_research_center.zip",
    "anim/kei_research_center2.zip",
    "anim/kei_research_space.zip",
    "anim/kei_material_research_centre.zip",
    "anim/kei_utilities_electric.zip",
    "anim/kei_utilities_electric_conduct.zip",
    "anim/kei_utilities_electric_conduct_hiwatt.zip",
    "anim/kei_logic_wires.zip",
    "anim/drone_icons_kei.zip",
}

local ATLAS_ASSETS = {
    "bigportraits/kei",
    "bigportraits/kei_none",
    "images/names_kei",
    "images/avatars/avatar_kei",
    "images/avatars/avatar_ghost_kei",
    "images/avatars/self_inspect_kei",
    "images/map_icons/kei",
    "images/map_icons/wandering_trader",
    "images/saveslot_portraits/kei",
    "images/inventoryimages/kei_items",
    "images/inventoryimages/kei_exp",
    "images/inventoryimages/kei_implant",
    "images/inventoryimages/kei_potential",
    "images/inventoryimages/kei_life_cd_item",
    "images/inventoryimages/kei_biome_cd_item",
    "images/inventoryimages/kei_beast_purple_cd_item",
    "images/inventoryimages/kei_beast_golden_cd_item",
    "images/inventoryimages/kei_protocol_binder",
    "images/inventoryimages/kei_mini_alice",
    "images/inventoryimages/kei_protocol_slot_states",
    "images/inventoryimages/transparent_slot",
    "images/inventoryimages/kei_alice_slot",
    "images/inventoryimages/analysis_cd_slot",
    "images/inventoryimages/kei_items_ir",
}

for _, path in ipairs(ANIM_ASSETS) do
    table.insert(Assets, Asset("ANIM", path))
end

for _, path in ipairs(ATLAS_ASSETS) do
    table.insert(Assets, Asset("ATLAS", path .. ".xml"))
    table.insert(Assets, Asset("IMAGE", path .. ".tex"))
end

PreloadAssets = {}
for _, path in ipairs({
    "anim/kei_status_power.zip",
    "anim/kei_status_stability.zip",
    "anim/kei_status_integrity.zip",
    "anim/kei_status_power_meter.zip",
    "anim/kei_status_stability_meter.zip",
    "anim/kei_status_integrity_meter.zip",
}) do
    table.insert(PreloadAssets, Asset("ANIM", path))
end

AddMinimapAtlas("images/map_icons/kei.xml")
AddMinimapAtlas("images/map_icons/wandering_trader.xml")
