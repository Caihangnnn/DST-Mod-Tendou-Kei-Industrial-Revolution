local CombatProtocolDefs = require("kei/protocols/combat")
local LifeProtocolDefs = require("kei/protocols/life")
local BasicAttributeProtocolDefs = require("kei/protocols/basic_attributes")
local Enchantment = require("kei/integrations/enchantment")

local COMMON_ITEM_ATLAS = "images/inventoryimages/kei_items.xml"
local COMMON_ITEM_BANK = "kei_item"
local COMMON_ITEM_BUILD = "kei_items"

local ITEM_VISUALS = {
    analysis_cd = {
        bank = COMMON_ITEM_BANK,
        build = COMMON_ITEM_BUILD,
        anim = "kei_analysis_cd_ground",
        atlas = COMMON_ITEM_ATLAS,
        image = "kei_analysis_cd",
        scale = 1.5,
    },
    analysis_tool = {
        bank = COMMON_ITEM_BANK,
        build = COMMON_ITEM_BUILD,
        anim = "kei_analysis_tool_ground",
        atlas = COMMON_ITEM_ATLAS,
        image = "kei_analysis_tool",
        scale = 1.5,
    },
    blank_cd = {
        bank = COMMON_ITEM_BANK,
        build = COMMON_ITEM_BUILD,
        anim = "kei_blank_cd_ground",
        atlas = COMMON_ITEM_ATLAS,
        image = "kei_blank_cd",
        scale = 1.5,
    },
    combat_cd = {
        bank = COMMON_ITEM_BANK,
        build = COMMON_ITEM_BUILD,
        anim = "kei_combat_cd_purple_ground",
        atlas = COMMON_ITEM_ATLAS,
        image = "kei_combat_cd_purple",
        scale = 1.5,
    },
    life_cd = {
        bank = "kei_life_cd",
        build = "kei_life_cd",
        anim = "kei_life_cd_ground",
        atlas = "images/inventoryimages/kei_life_cd_item.xml",
        image = "kei_life_cd",
        scale = 1.5,
    },
    battery = {
        bank = COMMON_ITEM_BANK,
        build = COMMON_ITEM_BUILD,
        anim = "kei_battery_ground",
        atlas = COMMON_ITEM_ATLAS,
        image = "kei_battery",
        scale = 1.5,
    },
    repair_tool = {
        bank = COMMON_ITEM_BANK,
        build = COMMON_ITEM_BUILD,
        anim = "kei_repair_tool_ground",
        atlas = COMMON_ITEM_ATLAS,
        image = "kei_repair_tool",
        scale = 1.5,
    },
}

local function AssetImagePath(visual)
    if visual == nil then
        return nil
    end
    if visual.tex ~= nil then
        return visual.tex
    end
    if visual.atlas ~= nil then
        return visual.atlas:gsub("%.xml$", ".tex")
    end
    return visual.image ~= nil and "images/inventoryimages/" .. visual.image .. ".tex" or nil
end

local function SetWorldScale(inst, scale)
    scale = scale or 1
    inst.Transform:SetScale(scale, scale, scale)
end

local function ConsumeOne(inst)
    if inst.components.stackable ~= nil then
        inst.components.stackable:Get():Remove()
    else
        inst:Remove()
    end
end

local function MakeKeiDeviceEdible(inst)
    inst:AddTag("quickeat")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.KEI_DEVICE
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = 0
    inst.components.edible.sanityvalue = 0
end

-- 多个简单道具都只需要动画、背包、堆叠和标签，因此抽成一个 prefab 工厂。
local function MakeSimpleInventoryItem(name, build, bank, anim, tags, image, postmaster, atlasname, scale)
    local assets = {
        Asset("ANIM", "anim/" .. build .. ".zip"),
    }
    if atlasname ~= nil then
        table.insert(assets, Asset("ATLAS", atlasname))
        table.insert(assets, Asset("IMAGE", atlasname:gsub("%.xml$", ".tex")))
    end

    local function fn()
        local inst = CreateEntity()

        -- 客户端和服务器都需要的网络实体基础组件。
        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank(bank or build)
        inst.AnimState:SetBuild(build)
        inst.AnimState:PlayAnimation(anim or "idle")
        SetWorldScale(inst, scale)

        if tags ~= nil then
            for _, tag in ipairs(tags) do
                inst:AddTag(tag)
            end
        end

        MakeInventoryFloatable(inst, "small", nil, 0.8)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            -- 客户端只负责表现，具体组件和状态只在主机端创建。
            return inst
        end

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")
        if image ~= nil then
            inst.components.inventoryitem.atlasname = atlasname
            inst.components.inventoryitem:ChangeImageName(image)
        end

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        if postmaster ~= nil then
            postmaster(inst)
        end

        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab(name, fn, assets)
end

local function ClearBoundTarget(inst)
    if inst.kei_bound_target ~= nil and inst.kei_bound_clear_fn ~= nil then
        inst:RemoveEventCallback("death", inst.kei_bound_clear_fn, inst.kei_bound_target)
        inst:RemoveEventCallback("onremove", inst.kei_bound_clear_fn, inst.kei_bound_target)
    end

    inst.kei_bound_prefab = nil
    inst.kei_bound_guid = nil
    inst.kei_bound_target = nil
    inst.kei_bound_clear_fn = nil
end

local function SetBoundTarget(inst, target)
    -- 空白 CD 记录一次绑定目标；目标死亡或移除后自动回到可重新绑定状态。
    ClearBoundTarget(inst)

    if target == nil then
        return
    end

    inst.kei_bound_prefab = target.prefab
    inst.kei_bound_guid = target.GUID
    inst.kei_bound_target = target
    inst.kei_bound_clear_fn = function(target_inst)
        if inst:IsValid() and inst.kei_bound_guid == target_inst.GUID then
            ClearBoundTarget(inst)
        end
    end
    inst:ListenForEvent("death", inst.kei_bound_clear_fn, target)
    inst:ListenForEvent("onremove", inst.kei_bound_clear_fn, target)
end

local function BlankCDOnSave(inst, data)
    -- 存档只保留 prefab 类型，避免把运行时实体引用写进存档。
    data.bound_prefab = inst.kei_bound_prefab
end

local function BlankCDOnLoad(inst, data)
    if data ~= nil then
        inst.kei_bound_prefab = data.bound_prefab
    end
end

local function MakeDeviceItem(name, visual_key, tags, max_stack_size, on_eaten)
    local visual = ITEM_VISUALS[visual_key]
    local assets = {
        Asset("ANIM", "anim/" .. visual.build .. ".zip"),
        Asset("ATLAS", visual.atlas),
        Asset("IMAGE", AssetImagePath(visual)),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)
        SetWorldScale(inst, visual.scale)
        inst.AnimState:SetBank(visual.bank)
        inst.AnimState:SetBuild(visual.build)
        inst.AnimState:PlayAnimation(visual.anim)

        if tags ~= nil then
            for _, tag in ipairs(tags) do
                inst:AddTag(tag)
            end
        end

        MakeInventoryFloatable(inst, "small", nil, 0.8)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = visual.atlas
        inst.components.inventoryitem:ChangeImageName(visual.image)

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = max_stack_size or TUNING.STACK_SIZE_SMALLITEM

        MakeKeiDeviceEdible(inst)
        if on_eaten ~= nil then
            inst.components.edible:SetOnEatenFn(on_eaten)
        end
        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab(name, fn, assets)
end

local function MakeBattery()
    return MakeDeviceItem("kei_battery", "battery", { "kei_battery" })
end

local function MakeRepairTool()
    return MakeDeviceItem("kei_repair_tool", "repair_tool", { "kei_repair_tool" })
end

local function ExperiencePackOnEaten(inst, eater)
    local experience = eater ~= nil
        and eater.components ~= nil
        and eater.components.kei_experience
        or nil
    if experience ~= nil then
        experience:DoDelta(TUNING.KEI_EXPERIENCE_PACK_AMOUNT or 1000)
    end
end

local function MakeExperiencePack()
    return MakeDeviceItem(
        "kei_experience_pack",
        "analysis_cd",
        { "kei_experience_pack" },
        40,
        ExperiencePackOnEaten
    )
end

local function MakeBlankCD()
    local visual = ITEM_VISUALS.blank_cd
    local assets = {
        Asset("ANIM", "anim/" .. visual.build .. ".zip"),
        Asset("ATLAS", visual.atlas),
        Asset("IMAGE", AssetImagePath(visual)),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)
        SetWorldScale(inst, visual.scale)
        inst.AnimState:SetBank(visual.bank)
        inst.AnimState:SetBuild(visual.build)
        inst.AnimState:PlayAnimation(visual.anim)

        inst:AddTag("kei_blank_cd")
        inst:AddTag("kei_data_cd")

        MakeInventoryFloatable(inst, "med", 0.02, 0.7)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = visual.atlas
        inst.components.inventoryitem:ChangeImageName(visual.image)
        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        inst.SetBoundTarget = SetBoundTarget
        inst.ClearBoundTarget = ClearBoundTarget
        -- 空白 CD 的绑定状态需要跨存档保留。
        inst.OnSave = BlankCDOnSave
        inst.OnLoad = BlankCDOnLoad
        inst:ListenForEvent("onremove", ClearBoundTarget)

        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab("kei_blank_cd", fn, assets)
end

local COMBAT_PROTOCOLS = CombatProtocolDefs.COMBAT_PROTOCOLS
local LIFE_PROTOCOLS = LifeProtocolDefs.LIFE_PROTOCOLS

local function GetPrefabDisplayName(prefab)
    return prefab ~= nil and (STRINGS.NAMES[string.upper(prefab)] or prefab) or nil
end

local function SetNamedName(inst, name)
    if name ~= nil and inst.components.named ~= nil then
        inst.components.named:SetName(name)
    end
end

local DEFAULT_ANALYSIS_VISUAL = {
    bank = ITEM_VISUALS.analysis_cd.bank,
    build = ITEM_VISUALS.analysis_cd.build,
    anim = ITEM_VISUALS.analysis_cd.anim,
    atlas = ITEM_VISUALS.analysis_cd.atlas,
    image = ITEM_VISUALS.analysis_cd.image,
    scale = ITEM_VISUALS.analysis_cd.scale,
}

local function UseEquipmentVisual()
    return TUNING.KEI_ANALYSIS_USE_EQUIPMENT_VISUAL == true
end

local function TrySetInventoryImage(inst, atlasname, imagename)
    if inst.components.inventoryitem == nil then
        return false
    end

    local success = pcall(function()
        inst.components.inventoryitem.atlasname = atlasname
        inst.components.inventoryitem:ChangeImageName(imagename)
    end)
    return success
end

local function SetInventoryImage(inst, imagename, atlasname)
    if inst.components.inventoryitem == nil then
        return
    end

    -- Native inventory images use a nil atlas and are resolved by the game.
    -- Try the saved source image first; external or stale assets are handled by
    -- the protected call and fall back to the registered Kei image.
    if TrySetInventoryImage(inst, atlasname, imagename or DEFAULT_ANALYSIS_VISUAL.image)
    then
        return
    end

    -- 外部模组被关闭或图标不存在时，只使用本模组已经注册的通用解析 CD 资源。
    TrySetInventoryImage(inst, DEFAULT_ANALYSIS_VISUAL.atlas, DEFAULT_ANALYSIS_VISUAL.image)
end

local function SetAnalysisVisualSkinBuild(inst, skin_build, base_build)
    local animstate = inst.AnimState
    if animstate == nil then
        return
    end

    -- SetAnalysisData can run more than once for an item copied from another
    -- CD. Remove the previous skin override before applying the new one.
    if inst.kei_analysis_visual_skin_build ~= nil
        and animstate.ClearOverrideBuild ~= nil
    then
        pcall(animstate.ClearOverrideBuild, animstate, inst.kei_analysis_visual_skin_build)
    end
    inst.kei_analysis_visual_skin_build = nil

    if skin_build ~= nil
        and skin_build ~= base_build
        and animstate.AddOverrideBuild ~= nil
    then
        local success = pcall(animstate.AddOverrideBuild, animstate, skin_build)
        if success then
            inst.kei_analysis_visual_skin_build = skin_build
        end
    end
end

local function TrySetAnalysisWorldAnimation(inst, bank, build, anim, skin_build)
    if bank == nil or build == nil or anim == nil then
        return false
    end

    local success, visual_valid = pcall(function()
        inst.AnimState:SetBank(bank)
        inst.AnimState:SetBuild(build)
        SetAnalysisVisualSkinBuild(inst, skin_build, build)
        inst.AnimState:PlayAnimation(anim)

        -- IsCurrentAnimation only confirms the requested name. A missing
        -- animation can still report that name, so also require real frames.
        local frame_count = inst.AnimState:GetCurrentAnimationNumFrames()
        local length = inst.AnimState:GetCurrentAnimationLength()
        return (type(bank) ~= "number" or inst.AnimState:GetBankHash() == bank)
            and inst.AnimState:GetBuild() == build
            and inst.AnimState:IsCurrentAnimation(anim)
            and (type(frame_count) ~= "number" or frame_count > 0)
            and (type(length) ~= "number" or length > 0)
    end)

    return success and visual_valid
end

local function SetAnalysisFloater(inst, floater_visual)
    local floater = inst.components ~= nil and inst.components.floater or nil
    if floater == nil or floater.SetBankSwapOnFloat == nil then
        return
    end

    if floater_visual ~= nil and floater_visual.do_bank_swap then
        floater:SetBankSwapOnFloat(
            true,
            floater_visual.float_index,
            floater_visual.swap_data
        )
    elseif floater_visual ~= nil and floater_visual.swap_data ~= nil
        and floater.SetSwapData ~= nil
    then
        floater:SetBankSwapOnFloat(false)
        floater:SetSwapData(floater_visual.swap_data)
    else
        floater:SetBankSwapOnFloat(false)
        if floater.SetSwapData ~= nil then
            floater:SetSwapData(nil)
        end
    end
end

local function SetAnalysisWorldAnimation(inst, bank, build, anim, skin_build, floater_visual)
    local use_default_visual = bank == nil and build == nil and anim == nil
    local source_visual_valid = not use_default_visual
        and TrySetAnalysisWorldAnimation(inst, bank, build, anim, skin_build)

    -- A few equipment prefabs expose a valid ground animation only through
    -- their floater swap data. Try that bank/animation before giving up.
    if not source_visual_valid
        and floater_visual ~= nil
        and floater_visual.swap_data ~= nil
    then
        local swap_data = floater_visual.swap_data
        source_visual_valid = TrySetAnalysisWorldAnimation(
            inst,
            swap_data.bank,
            build,
            swap_data.anim,
            skin_build
        )
    end

    if source_visual_valid then
        SetWorldScale(inst, 1)
        SetAnalysisFloater(inst, floater_visual)
        return true
    end

    -- 外部动画 bank、build 或 anim 不存在时回退到通用解析 CD 地面动画。
    local fallback_success = TrySetAnalysisWorldAnimation(
        inst,
        DEFAULT_ANALYSIS_VISUAL.bank,
        DEFAULT_ANALYSIS_VISUAL.build,
        DEFAULT_ANALYSIS_VISUAL.anim
    )
    SetAnalysisFloater(inst, nil)
    SetWorldScale(inst, DEFAULT_ANALYSIS_VISUAL.scale)
    return fallback_success
end

local WORLD_ANIM_CANDIDATES = {
    "anim",
    "idle",
    "idle_loop",
    "idle1",
    "idle2",
    "idle3",
    "idle4",
}

local function GetCurrentOrFallbackAnim(source, fallback)
    if source ~= nil and source.AnimState ~= nil then
        if source.AnimState.GetCurrentAnimationName ~= nil then
            local success, current = pcall(
                source.AnimState.GetCurrentAnimationName,
                source.AnimState
            )
            if success
                and type(current) == "string"
                and current ~= ""
                and current ~= "FROMNUM"
            then
                return current
            end
        end

        for _, anim in ipairs(WORLD_ANIM_CANDIDATES) do
            if source.AnimState:IsCurrentAnimation(anim) then
                return anim
            end
        end
    end
    return fallback or "anim"
end

local function GetSkinBuild(source)
    if source == nil or source.GetSkinBuild == nil then
        return nil
    end
    local success, skin_build = pcall(source.GetSkinBuild, source)
    return success and skin_build or nil
end

local function GetAnalysisVisualFromSource(data)
    if data == nil or data.source == nil then
        return nil, true
    end

    local success, source = pcall(SpawnPrefab, data.source, data.skin_name)
    if not success then
        source = nil
    end
    if source == nil then
        return nil, false
    end

    source:AddTag("INLIMBO")
    if source.Hide ~= nil then
        source:Hide()
    elseif source.entity ~= nil and source.entity.Hide ~= nil then
        source.entity:Hide()
    end
    if source.components.inventoryitem ~= nil and source.components.inventoryitem.Hide ~= nil then
        source.components.inventoryitem:Hide()
    end

    local visual = nil
    if source.AnimState ~= nil then
        local visual_success, visual_data = pcall(function()
            local floater = source.components ~= nil and source.components.floater or nil
            local swap_data = floater ~= nil and floater.swap_data or nil
            local copied_swap_data = nil
            if floater ~= nil and swap_data ~= nil then
                copied_swap_data = {
                    bank = swap_data.bank,
                    anim = swap_data.anim,
                    sym_build = swap_data.sym_build,
                    sym_name = swap_data.sym_name,
                }
            end

            return {
                bank = source.AnimState:GetBankHash() or data.visual_bank,
                build = source.AnimState:GetBuild() or data.visual_build,
                anim = GetCurrentOrFallbackAnim(source, data.visual_anim),
                skin_build = data.skin_build or GetSkinBuild(source),
                floater = floater ~= nil and {
                    do_bank_swap = floater.do_bank_swap == true,
                    float_index = floater.float_index,
                    swap_data = copied_swap_data,
                } or nil,
            }
        end)
        visual = visual_success and visual_data or nil
    end

    if source.Remove ~= nil then
        source:Remove()
    end
    return visual, true
end

local function ApplyAnalysisAppearance(inst, data, icon_image, visual)
    if UseEquipmentVisual() and data.source ~= nil then
        SetInventoryImage(inst, icon_image, data.icon_atlas)
        SetAnalysisWorldAnimation(
            inst,
            visual ~= nil and visual.bank or nil,
            visual ~= nil and visual.build or nil,
            visual ~= nil and visual.anim or nil,
            visual ~= nil and visual.skin_build or nil,
            visual ~= nil and visual.floater or nil
        )
    else
        SetInventoryImage(inst, DEFAULT_ANALYSIS_VISUAL.image, DEFAULT_ANALYSIS_VISUAL.atlas)
        SetAnalysisWorldAnimation(inst)
    end
end

local function ApplyFixedProtocolData(inst, def, kind)
    inst.kei_protocol_definition = def
    inst.kei_protocol_data = {
        kind = kind,
        protocol = def.protocol,
        source = def.source_protocol or def.protocol,
        category = def.category or kind,
        tier = def.tier,
        display_name = def.display_name,
        implemented = def.implemented == true,
    }

    if kind == "basic_attribute" then
        local min_value = TUNING["KEI_BASIC_ATTRIBUTE_" .. string.upper(def.attribute) .. "_MIN"] or def.range_min
        local max_value = TUNING["KEI_BASIC_ATTRIBUTE_" .. string.upper(def.attribute) .. "_MAX"] or def.range_max
        inst.kei_protocol_data.attribute = def.attribute
        inst.kei_protocol_data.attribute_value = math.random(min_value, max_value)
    end

    if kind == "combat" then
        inst.kei_combat_protocol = def.protocol
        SetNamedName(inst, (def.display_name or def.protocol) .. "战斗协议")
    elseif kind == "life" then
        inst.kei_life_protocol = def.protocol
        SetNamedName(inst, def.display_name or def.protocol)
    elseif kind == "basic_attribute" then
        inst.kei_basic_attribute_protocol = def.protocol
        SetNamedName(inst, (def.display_name or def.protocol) .. "基础属性协议")
    end
end

local function FixedProtocolDescriptionFn(inst)
    local def = inst.kei_protocol_definition
    if def == nil then
        return nil
    end
    if def.kind == "basic_attribute"
        and inst.kei_protocol_data ~= nil
        and inst.kei_protocol_data.attribute_value ~= nil
    then
        local value = inst.kei_protocol_data.attribute_value
        local suffix = def.is_percent and "%" or ""
        return (def.description or "") .. "\n当前数值: " .. tostring(value) .. suffix
    end
    return def.description
end

local function FixedProtocolOnSave(inst, data)
    if data ~= nil
        and inst.kei_protocol_data ~= nil
        and inst.kei_protocol_data.kind == "basic_attribute"
    then
        data.attribute_value = inst.kei_protocol_data.attribute_value
    end
end

local function FixedProtocolOnLoad(inst, data)
    if inst.kei_protocol_data ~= nil
        and inst.kei_protocol_data.kind == "basic_attribute"
        and data ~= nil
        and data.attribute_value ~= nil
    then
        inst.kei_protocol_data.attribute_value = tonumber(data.attribute_value) or inst.kei_protocol_data.attribute_value
    end
end

local function MakeFixedProtocolCD(def, kind, visual_key, tags, deps)
    local visual = ITEM_VISUALS[visual_key]
    if kind == "combat" and CombatProtocolDefs.GetProtocolVisual ~= nil then
        visual = CombatProtocolDefs.GetProtocolVisual(def.protocol) or visual
    end
    local assets = {
        Asset("ANIM", "anim/" .. visual.build .. ".zip"),
        Asset("ATLAS", visual.atlas),
        Asset("IMAGE", AssetImagePath(visual)),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)
        SetWorldScale(inst, visual.scale)
        inst.AnimState:SetBank(visual.bank)
        inst.AnimState:SetBuild(visual.build)
        inst.AnimState:PlayAnimation(visual.anim)

        inst:AddTag("kei_protocol_cd")
        if tags ~= nil then
            for _, tag in ipairs(tags) do
                inst:AddTag(tag)
            end
        end

        MakeInventoryFloatable(inst, kind == "combat" and "med" or "small", kind == "combat" and 0.02 or nil, kind == "combat" and 0.7 or 0.8)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")
        inst.components.inspectable.descriptionfn = FixedProtocolDescriptionFn
        inst:AddComponent("named")
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = visual.atlas
        inst.components.inventoryitem:ChangeImageName(visual.image)
        inst.components.inventoryitem.keepondeath = true

        ApplyFixedProtocolData(inst, def, kind)
        inst.OnSave = FixedProtocolOnSave
        inst.OnLoad = FixedProtocolOnLoad
        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab(def.prefab, fn, assets, deps)
end

local function MakeCombatProtocolCDs()
    local prefabs = {}
    for _, def in ipairs(CombatProtocolDefs.COMBAT_PROTOCOL_LIST) do
        table.insert(prefabs, MakeFixedProtocolCD(def, "combat", "combat_cd", { "kei_combat_protocol", "kei_data_cd" }, { "buff_electricattack", "electrichitsparks", "electrichitsparks_electricimmune", "shock_arc_fx", "electricchargedfx", "kei_rook_shield_pulse_fx" }))
    end
    return prefabs
end

local function MakeLifeProtocolCDs()
    local prefabs = {}
    for _, def in ipairs(LifeProtocolDefs.LIFE_PROTOCOL_LIST) do
        table.insert(prefabs, MakeFixedProtocolCD(def, "life", "life_cd", { "kei_life_protocol" }))
    end
    return prefabs
end

local function MakeBasicAttributeProtocolCDs()
    local prefabs = {}
    for _, def in ipairs(BasicAttributeProtocolDefs.BASIC_ATTRIBUTE_PROTOCOL_LIST) do
        table.insert(prefabs, MakeFixedProtocolCD(
            def,
            "basic_attribute",
            "blank_cd",
            { "kei_basic_attribute_protocol" },
            nil
        ))
    end
    return prefabs
end

local function GetProtocolPrefabs(definitions, predicate)
    local prefabs = {}
    for _, def in ipairs(definitions or {}) do
        if def.prefab ~= nil and (predicate == nil or predicate(def)) then
            table.insert(prefabs, def.prefab)
        end
    end
    return prefabs
end

local function GiveUnwrappedItemToDoer(item, doer, pos)
    if item == nil or not item:IsValid() then
        return false
    end

    local inventory = doer ~= nil and doer.components ~= nil and doer.components.inventory or nil
    if inventory ~= nil and inventory:GiveItem(item, nil, doer:GetPosition()) then
        return true
    end

    if item.Physics ~= nil then
        item.Physics:Teleport(pos:Get())
    else
        item.Transform:SetPosition(pos:Get())
    end
    if item.components ~= nil and item.components.inventoryitem ~= nil then
        item.components.inventoryitem:OnDropped(true, .5)
    end
    return false
end

local function ChooseGiftRewardPrefab(reward_prefabs, doer)
    if doer == nil or doer.components == nil or doer.components.kei_taskbook == nil then
        return reward_prefabs[math.random(#reward_prefabs)]
    end

    local taskbook = doer.components.kei_taskbook
    if taskbook.ShouldPreferUnrecordedCombat == nil
        or not taskbook:ShouldPreferUnrecordedCombat()
    then
        return reward_prefabs[math.random(#reward_prefabs)]
    end

    local unrecorded = {}
    for _, prefab in ipairs(reward_prefabs) do
        if not taskbook:IsCombatProtocolRecorded(prefab) then
            table.insert(unrecorded, prefab)
        end
    end

    local candidates = #unrecorded > 0 and unrecorded or reward_prefabs
    local previous = taskbook._kei_last_preferred_combat_reward
    if #candidates > 1 and previous ~= nil then
        local without_previous = {}
        for _, prefab in ipairs(candidates) do
            if prefab ~= previous then
                table.insert(without_previous, prefab)
            end
        end
        if #without_previous > 0 then
            candidates = without_previous
        end
    end

    local selected = candidates[math.random(#candidates)]
    taskbook._kei_last_preferred_combat_reward = selected
    return selected
end

local function RerollGiftReward(component, reward_prefabs, doer)
    -- WrapItems stores the generated item's serialized data. Clear the old
    -- cache first so a reroll cannot leave the previous reward in itemdata.
    component.itemdata = nil
    component:WrapItems({ ChooseGiftRewardPrefab(reward_prefabs, doer) })
end

local function MakeRandomCDGift(name, display_name, visual_key, image, ground_anim, reward_prefabs)
    local visual = ITEM_VISUALS[visual_key]
    local assets = {
        Asset("ANIM", "anim/" .. visual.build .. ".zip"),
        Asset("ATLAS", visual.atlas),
        Asset("IMAGE", AssetImagePath(visual)),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)
        SetWorldScale(inst, visual.scale)
        inst.AnimState:SetBank(visual.bank)
        inst.AnimState:SetBuild(visual.build)
        inst.AnimState:PlayAnimation(ground_anim or visual.anim)
        -- The action picker needs this tag on clients before components replicate.
        inst:AddTag("unwrappable")

        MakeInventoryFloatable(inst, "small", nil, .8)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")
        inst.components.inspectable.descriptionfn = function()
            return "右键拆开，获得一个随机协议 CD。"
        end
        inst:AddComponent("named")
        inst.components.named:SetName(display_name)
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = visual.atlas
        inst.components.inventoryitem:ChangeImageName(image)
        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        inst:AddComponent("unwrappable")
        if #reward_prefabs > 0 then
            -- Wrap a generated CD record so both the CD type and any randomized
            -- basic-attribute value are fixed when the gift is awarded.
            inst.components.unwrappable:WrapItems({ reward_prefabs[math.random(#reward_prefabs)] })
        else
            inst.components.unwrappable.canbeunwrapped = false
        end
        inst.components.unwrappable:SetOnUnwrappedFn(function(gift, pos, doer)
            local stackable = gift.components.stackable
            local stacksize = stackable ~= nil and stackable:StackSize() or 1
            if stacksize > 1 then
                stackable:SetStackSize(stacksize - 1)
                RerollGiftReward(gift.components.unwrappable, reward_prefabs, doer)
            else
                gift:Remove()
            end
        end)

        -- The default unwrappable component always drops its contents on the
        -- ground and consumes the whole stack. Gift boxes need one-at-a-time
        -- opening so stacked boxes produce the same number of CDs.
        local unwrappable = inst.components.unwrappable
        unwrappable.Unwrap = function(component, doer)
            -- The reward is selected when the box is opened, because the
            -- preference and recorded protocols belong to the opener.
            if doer ~= nil and doer.components ~= nil
                and doer.components.kei_taskbook ~= nil
                and doer.components.kei_taskbook:ShouldPreferUnrecordedCombat()
            then
                RerollGiftReward(component, reward_prefabs, doer)
            end
            local itemdata = component.itemdata
            local pos = component.inst:GetPosition()
            pos.y = 0
            if itemdata ~= nil then
                local creator = component.origin ~= nil
                    and TheWorld.meta.session_identifier ~= component.origin
                    and { sessionid = component.origin }
                    or nil
                for _, data in ipairs(itemdata) do
                    local item = SpawnPrefab(data.prefab, data.skinname, data.skin_id, creator)
                    if item ~= nil and item:IsValid() then
                        item:SetPersistData(data.data)
                        GiveUnwrappedItemToDoer(item, doer, pos)
                        item:PushEvent("unwrappeditem", { bundle = component.inst, doer = doer })
                    end
                end
                component.itemdata = nil
            end
            component.inst:PushEvent("unwrapped", { doer = doer })
            if component.onunwrappedfn ~= nil then
                component.onunwrappedfn(component.inst, pos, doer)
            end
        end

        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab(name, fn, assets, reward_prefabs)
end

local function SetAnalysisData(inst, data)
    -- 解析 CD 保存装备解析结果，字段由 kei_actions.lua 的 AnalyzeEquipment 生成。
    data = data or {}
    local source_name = data.display_name or GetPrefabDisplayName(data.source)
    local icon_image = data.icon_image or data.source
    local damage_bonus = data.damage_bonus
    if damage_bonus == nil and data.damage_mult ~= nil and data.damage_mult > 1 then
        damage_bonus = data.damage_mult * TUNING.UNARMED_DAMAGE
    end

    local source_visual, source_exists = GetAnalysisVisualFromSource(data)
    if not source_exists then
        -- 解析结果依赖的原装备已经不存在，不能让失效 CD 进入协议槽。
        inst:Remove()
        return false
    end

    inst.kei_protocol_data = {
        kind = "analysis",
        slot = data.slot or "hands",
        source = data.source,
        display_name = source_name,
        icon_image = icon_image,
        icon_atlas = data.icon_atlas,
        visual_bank = data.visual_bank,
        visual_build = data.visual_build,
        visual_anim = data.visual_anim,
        skin_name = data.skin_name,
        skin_build = data.skin_build,
        full_equipment = data.full_equipment == true,
        enchantments = data.enchantments,
        absorb = data.absorb or 0,
        damage_bonus = damage_bonus or 0,
        speed_mult = data.speed_mult or 1,
        planar_bonus = data.planar_bonus or 0,
        tool_actions = data.tool_actions,
        tool_tough = data.tool_tough or nil,
    }
    Enchantment.Apply(inst, inst.kei_protocol_data.enchantments)
    ApplyAnalysisAppearance(inst, data, icon_image, source_visual)
    SetNamedName(inst, source_name ~= nil and ("数据化的 " .. source_name) or nil)
end

local function AnalysisCDOnSave(inst, data)
    data.protocol = inst.kei_protocol_data
end

local function AnalysisCDOnLoad(inst, data)
    inst:SetAnalysisData(data ~= nil and data.protocol or nil)
end

local function MakeAnalysisCD()
    local visual = ITEM_VISUALS.analysis_cd
    local assets = {
        Asset("ANIM", "anim/" .. visual.build .. ".zip"),
        Asset("ATLAS", visual.atlas),
        Asset("IMAGE", AssetImagePath(visual)),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)
        SetAnalysisWorldAnimation(inst)

        inst:AddTag("kei_protocol_cd")
        inst:AddTag("kei_analysis_protocol")

        MakeInventoryFloatable(inst, "small", nil, 0.8)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inspectable")
        inst:AddComponent("named")
        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.atlasname = visual.atlas
        inst.components.inventoryitem:ChangeImageName(visual.image)
        inst.components.inventoryitem.keepondeath = true

        inst.SetAnalysisData = SetAnalysisData
        inst.OnSave = AnalysisCDOnSave
        inst.OnLoad = AnalysisCDOnLoad
        -- 没有数据时给出安全默认值，避免 nil 字段影响协议槽刷新。
        inst:SetAnalysisData()

        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab("kei_analysis_cd", fn, assets)
end

-- 核心协议道具统一使用 ITEM_VISUALS 中登记的专用贴图和地面动画。
local prefabs = {
    MakeBattery(),
    MakeRepairTool(),
    MakeExperiencePack(),
    MakeSimpleInventoryItem(
        "kei_analysis_tool",
        ITEM_VISUALS.analysis_tool.build,
        ITEM_VISUALS.analysis_tool.bank,
        ITEM_VISUALS.analysis_tool.anim,
        { "kei_analysis_tool" },
        ITEM_VISUALS.analysis_tool.image,
        nil,
        ITEM_VISUALS.analysis_tool.atlas,
        ITEM_VISUALS.analysis_tool.scale
    ),
    MakeBlankCD(),
    MakeAnalysisCD(),
    MakeRandomCDGift(
        "kei_blank_cd_random", "白色CD礼盒", "blank_cd", "kei_blank_cd_random",
        "kei_blank_cd_random_ground",
        GetProtocolPrefabs(BasicAttributeProtocolDefs.BASIC_ATTRIBUTE_PROTOCOL_LIST)
    ),
    MakeRandomCDGift(
        "kei_combat_cd_blue_random", "蓝色CD礼盒", "combat_cd", "kei_combat_cd_blue_random",
        "kei_combat_cd_blue_random_ground",
        GetProtocolPrefabs(CombatProtocolDefs.COMBAT_PROTOCOL_LIST, function(def) return def.category == "biome" end)
    ),
    MakeRandomCDGift(
        "kei_combat_cd_golden_random", "金色CD礼盒", "combat_cd", "kei_combat_cd_golden_random",
        "kei_combat_cd_golden_random_ground",
        GetProtocolPrefabs(CombatProtocolDefs.COMBAT_PROTOCOL_LIST, function(def)
            return def.category == "beast" and def.tier == "basic"
        end)
    ),
    MakeRandomCDGift(
        "kei_combat_cd_purple_random", "紫色CD礼盒", "combat_cd", "kei_combat_cd_purple_random",
        "kei_combat_cd_purple_random_ground",
        GetProtocolPrefabs(CombatProtocolDefs.COMBAT_PROTOCOL_LIST, function(def)
            return def.category == "beast" and def.tier ~= "basic"
        end)
    ),
}


for _, prefab in ipairs(MakeCombatProtocolCDs()) do
    table.insert(prefabs, prefab)
end
for _, prefab in ipairs(MakeLifeProtocolCDs()) do
    table.insert(prefabs, prefab)
end
for _, prefab in ipairs(MakeBasicAttributeProtocolCDs()) do
    table.insert(prefabs, prefab)
end

return unpack(prefabs)
