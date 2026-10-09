local MakePlayerCharacter = require("prefabs/player_common")
local PlayerCommonExtensions = require("prefabs/player_common_extensions")
local EyeOfTerrorDash = require("kei/protocols/combat/effects/beast/_eyeofterror_dash")
local DaywalkerLeap = require("kei/protocols/combat/effects/beast/_daywalker_leap")
local RookGuard = require("kei/protocols/combat/effects/biome/rook")
local PowerStat = require("kei/stats/power")
local StabilityStat = require("kei/stats/stability")
local IntegrityStat = require("kei/stats/integrity")
local Recovery = require("kei/stats/recovery")
local KeiBackupBody = require("kei/growth/backup_body")
local RotorSurveySkills = require("kei/drone/skills")
local RotorSurveyRegistry = require("kei/drone/registry")
local ClientSettings = require("kei/client_settings")

local assets = {
    Asset("SCRIPT", "scripts/prefabs/player_common.lua"),
    -- The FEV is registered globally; the FSB is attached to the character
    -- prefab just like the reference character's voice bank.
    Asset("SOUND", "sound/tendou_kei_vc.fsb"),
    Asset("SOUND", "sound/kei_hit_sound.fsb"),
    Asset("SOUND", "sound/kei_carol_a01.fsb"),
    Asset("ANIM", "anim/kei.zip"),
    Asset("ANIM", "anim/ghost_kei_build.zip"),
    Asset("ANIM", "anim/player_idles_kei.zip"),
    Asset("ANIM", "anim/wx_chassis.zip"),
    Asset("ANIM", "anim/kei_status_power.zip"),
    Asset("ANIM", "anim/kei_status_stability.zip"),
    Asset("ANIM", "anim/kei_status_integrity.zip"),
    Asset("ANIM", "anim/kei_status_power_meter.zip"),
    Asset("ANIM", "anim/kei_status_stability_meter.zip"),
    Asset("ANIM", "anim/kei_status_integrity_meter.zip"),
}

local prefabs = {
    "kei_battery",
    "kei_dormant_chassis",
    "kei_backupbody",
    "kei_protocol_container",
    "kei_protocol_binder",
    "kei_mini_alice",
    "minerhatlight",
    "reticuleaoe",
    "reticuleaoeping",
    "reticuleline",
    "reticulelineping",
    "kei_mutatedwarg_flamethrower",
    "kei_celestial_orb_fx",
    "kei_moose_tornado",
    "warg_mutated_breath_fx",
    "warg_mutated_ember_fx",
    "daywalker_sinkhole",
    "bigshadowtentacle",
    "shadow_pillar",
    "shadow_pillar_target",
    "waxwell_shadowstriker",
    "shadowstrike_slash_fx",
    "shadowstrike_slash2_fx",
    "statue_transition_2",
    "wortox_soul",
    "wortox_soul_heal_fx",
    "sleepbomb",
    "sleepbomb_burst",
    "sleepcloud",
    "sandspike_tall",
    "sandspike_short",
    "battlesong_instant_panic_fx",
    "collapse_small",
    "wx78_big_spark",
    "hermitcrab_fx_med",
    "kei_rook_shield_pulse_fx",
}

local KEI_LIGHT_CHECK_PERIOD = 0.5
local KEI_LIGHT_RADIUS = 1
local KEI_LIGHT_FALLOFF = 0.6
local KEI_LIGHT_INTENSITY = 0.35
local KEI_LIGHT_COLOUR = { 240 / 255, 187 / 255, 203 / 255 }

-- 初始物品提供少量电池和一个解析工具，方便角色刚进世界时开始使用核心流程。
local start_inv = {
    "kei_battery",
    "kei_battery",
    "kei_battery",
    "kei_analysis_tool",
}

local MINI_ALICE_SLOT = 8

local function FindMiniAliceItem(inst)
    local inventory = inst ~= nil and inst.components ~= nil and inst.components.inventory or nil
    if inventory == nil then
        return nil
    end

    for slot = 1, inventory:GetNumSlots() do
        local item = inventory:GetItemInSlot(slot)
        if item ~= nil and item:HasTag("kei_mini_alice") then
            return item
        end
    end
end

local function RelocateReplacedInventoryItem(inst, item)
    if item == nil then
        return false
    end

    local inventory = inst ~= nil and inst.components ~= nil and inst.components.inventory or nil
    if inventory ~= nil then
        -- The Alice slot is reserved. Reinsert displaced items into another
        -- inventory slot before falling back to dropping them on the ground.
        for slot = 1, inventory.maxslots do
            if slot ~= MINI_ALICE_SLOT
                and inventory:GetItemInSlot(slot) == nil
                and inventory:GiveItem(item, slot)
            then
                return true
            end
        end
    end

    item.Transform:SetPosition(inst.Transform:GetWorldPosition())
    if item.components ~= nil and item.components.inventoryitem ~= nil then
        item.components.inventoryitem:OnDropped(true)
    end
    inst:PushEvent("dropitem", { item = item })
    return false
end

local function EnsureMiniAliceItem(inst)
    if not TheWorld.ismastersim
        or inst == nil
        or not inst:IsValid()
        or inst.components == nil
        or inst.components.inventory == nil
    then
        return
    end

    local inventory = inst.components.inventory
    local icon = inventory:GetItemInSlot(MINI_ALICE_SLOT)

    if icon ~= nil and icon:HasTag("kei_mini_alice") then
        icon.components.inventoryitem.islockedinslot = true
        return
    end

    local displaced = nil
    if icon ~= nil then
        displaced = inventory:RemoveItemBySlot(MINI_ALICE_SLOT)
    end

    icon = FindMiniAliceItem(inst)
    if icon == nil then
        icon = SpawnPrefab("kei_mini_alice")
        if icon == nil then
            RelocateReplacedInventoryItem(inst, displaced)
            return
        end
    else
        icon = inventory:RemoveItem(icon, true)
        if icon == nil then
            RelocateReplacedInventoryItem(inst, displaced)
            return
        end
    end

    inventory.ignoresound = true
    local inserted = inventory:GiveItem(icon, MINI_ALICE_SLOT)
    inventory.ignoresound = false
    if not inserted then
        inventory:GiveItem(icon, nil, inst:GetPosition())
    end

    if displaced ~= nil then
        RelocateReplacedInventoryItem(inst, displaced)
    end
end

local function OpenMiniAlice(inst)
    if not TheWorld.ismastersim
        or inst == nil
        or not inst:IsValid()
        or inst:HasTag("playerghost")
        or inst.components == nil
        or inst.components.inventory == nil
    then
        return
    end

    local alice = FindMiniAliceItem(inst)
    local container = alice ~= nil
        and alice.components ~= nil
        and alice.components.container
        or nil
    if container ~= nil and not container:IsOpenedBy(inst) then
        container:Open(inst)
    end
end

local function ScheduleOpenMiniAlice(inst, delay)
    if inst == nil or not inst:IsValid() then
        return
    end
    if inst._kei_mini_alice_open_task ~= nil then
        return
    end

    inst._kei_mini_alice_open_task = inst:DoTaskInTime(delay or 0, function(owner)
        owner._kei_mini_alice_open_task = nil
        EnsureMiniAliceItem(owner)
        OpenMiniAlice(owner)
    end)
end

local function OnKeiRespawnedFromGhost(inst)
    ScheduleOpenMiniAlice(inst, 0.1)
end

local function EnsureRotorSurveyController(inst)
    if not TheWorld.ismastersim
        or inst == nil
        or not inst:IsValid()
        or inst.components == nil
        or inst.components.inventory == nil
    then
        return
    end

    local controller = RotorSurveyRegistry.FindControllerInOwner(inst)
    if controller ~= nil then
        if controller.SetControllerOwner ~= nil then
            controller:SetControllerOwner(inst)
        end
        return
    end

    controller = SpawnPrefab("kei_rotor_survey_controller")
    if controller == nil then
        return
    end
    if controller.SetControllerOwner ~= nil then
        controller:SetControllerOwner(inst)
    end

    local inventory = inst.components.inventory
    if inventory:GiveItem(controller) then
        return
    end

    -- 控制器限定在主物品栏；物品栏已满时按原有失败路径放在角色位置。
    controller.Transform:SetPosition(inst.Transform:GetWorldPosition())
end

local function SetReticulePrefab(reticule, prefab)
    if reticule == nil then
        return
    end
    if reticule.reticuleprefab ~= prefab and reticule.reticule ~= nil then
        reticule:DestroyReticule()
    end
    reticule.reticuleprefab = prefab
end

local function ConfigureEyeOfTerrorReticule(inst)
    local reticule = inst.components.reticule
    if reticule == nil then
        return
    end
    SetReticulePrefab(reticule, "reticuleline")
    reticule.pingprefab = nil
    reticule.targetfn = EyeOfTerrorDash.ReticuleTargetFn
    reticule.mousetargetfn = EyeOfTerrorDash.ReticuleMouseTargetFn
    reticule.updatepositionfn = EyeOfTerrorDash.ReticuleUpdatePositionFn
    reticule.validcolour = { 1, 0.2, 0.2, 0 }
    reticule.invalidcolour = { 0.5, 0, 0, 0 }
    reticule.twinstickrange = TUNING.KEI_EYEOFTERROR_DASH_DISTANCE or 12
end

local function ConfigureDaywalkerReticule(inst)
    local reticule = inst.components.reticule
    if reticule == nil then
        return
    end
    SetReticulePrefab(reticule, "reticuleaoe")
    reticule.pingprefab = "reticuleaoeping"
    reticule.targetfn = DaywalkerLeap.ReticuleTargetFn
    reticule.mousetargetfn = DaywalkerLeap.ReticuleMouseTargetFn
    reticule.updatepositionfn = nil
    reticule.validcolour = { 1, 0.75, 0, 1 }
    reticule.invalidcolour = { 0.5, 0, 0, 1 }
    reticule.twinstickrange = TUNING.KEI_DAYWALKER_LEAP_DISTANCE or 7
end

local function UpdateDaywalkerAimingReticule(inst)
    if inst.components.reticule == nil then
        return
    end
    if ThePlayer == inst
        and inst._kei_daywalker_aiming ~= nil
        and inst._kei_daywalker_aiming:value()
        and DaywalkerLeap.IsReady(inst)
    then
        ConfigureDaywalkerReticule(inst)
        inst.components.reticule:CreateReticule()
    else
        inst.components.reticule:DestroyReticule()
    end
end

local function SetWaterWalkCollision(inst, enabled)
    if enabled and not TheWorld:HasTag("cave") and not inst:HasTag("playerghost") then
        inst.Physics:SetCollisionMask(
            COLLISION.GROUND,
            COLLISION.OBSTACLES,
            COLLISION.SMALLOBSTACLES,
            COLLISION.CHARACTERS,
            COLLISION.GIANTS
        )
    elseif not inst:HasTag("playerghost") then
        inst.Physics:SetCollisionMask(
            COLLISION.WORLD,
            COLLISION.OBSTACLES,
            COLLISION.SMALLOBSTACLES,
            COLLISION.CHARACTERS,
            COLLISION.GIANTS
        )
    end
end

local function OnWaterWalkProtocolDirty(inst)
    SetWaterWalkCollision(
        inst,
        inst._kei_water_walk_protocol_active ~= nil and inst._kei_water_walk_protocol_active:value()
    )
end

local function CanUseRookGuard(inst)
    return ACTIONS.KEI_ROOK_GUARD ~= nil
        and RookGuard.HasProtocol(inst)
        and RookGuard.IsReady(inst)
        and not inst:HasTag("playerghost")
        and (inst.replica.inventory == nil or inst.replica.inventory:GetActiveItem() == nil)
end

local GetRightClickDashPoint

local function GetPointSpecialActions(inst, pos, useitem, right, usereticulepos)
    -- 地图打开时才提供原版 MAPSCOUTSELECT_MAP；有效目标与所有权由动作回调校验。
    if inst.checkingmapactions
        and right
        and useitem == nil
        and ACTIONS.MAPSCOUTSELECT_MAP ~= nil
        and not inst:HasTag("playerghost")
    then
        return { ACTIONS.MAPSCOUTSELECT_MAP }, pos
    end

    if ACTIONS.KEI_DAYWALKER_LEAP ~= nil
        and DaywalkerLeap.HasProtocol(inst)
        and DaywalkerLeap.IsAiming(inst)
        and DaywalkerLeap.IsReady(inst)
        and not inst:HasTag("playerghost")
    then
        ConfigureDaywalkerReticule(inst)
        local targetpos = usereticulepos and DaywalkerLeap.ReticuleTargetFn(inst) or DaywalkerLeap.GetTargetPoint(inst, pos)
        if targetpos ~= nil then
            return { right and ACTIONS.KEI_DAYWALKER_CANCEL_AIM or ACTIONS.KEI_DAYWALKER_LEAP }, targetpos
        end
        return right and { ACTIONS.KEI_DAYWALKER_CANCEL_AIM } or {}
    end

    if right and useitem == nil then
        for _, action in ipairs(ClientSettings:GetRightClickPriority()) do
            if action == "guard" and CanUseRookGuard(inst) then
                return { ACTIONS.KEI_ROOK_GUARD }, pos or inst:GetPosition()
            elseif action == "leap"
                and ACTIONS.KEI_DAYWALKER_AIM ~= nil
                and DaywalkerLeap.HasProtocol(inst)
                and DaywalkerLeap.IsReady(inst)
                and not inst:HasTag("playerghost")
            then
                ConfigureDaywalkerReticule(inst)
                local targetpos = usereticulepos and DaywalkerLeap.ReticuleTargetFn(inst) or DaywalkerLeap.GetTargetPoint(inst, pos)
                if targetpos ~= nil then
                    return { ACTIONS.KEI_DAYWALKER_AIM }, targetpos
                end
            elseif action == "dash" then
                local targetpos = GetRightClickDashPoint(inst, nil, pos, true)
                if targetpos ~= nil then
                    return { ACTIONS.KEI_EYEOFTERROR_DASH }, targetpos
                end
            end
        end
    end
    return {}
end

local function DaywalkerAimLeftClickPicker(inst, target, position)
    if ACTIONS.KEI_DAYWALKER_LEAP ~= nil
        and DaywalkerLeap.HasProtocol(inst)
        and DaywalkerLeap.IsAiming(inst)
        and DaywalkerLeap.IsReady(inst)
        and position ~= nil
        and not inst:HasTag("playerghost")
    then
        local targetpos = DaywalkerLeap.GetTargetPoint(inst, position)
        return targetpos ~= nil and inst.components.playeractionpicker:SortActionList({ ACTIONS.KEI_DAYWALKER_LEAP }, targetpos) or {}
    end
    if inst._kei_old_leftclickoverride ~= nil then
        return inst._kei_old_leftclickoverride(inst, target, position)
    end
    return nil, true
end

GetRightClickDashPoint = function(inst, target, position, allow_point)
    if ACTIONS.KEI_EYEOFTERROR_DASH == nil
        or not EyeOfTerrorDash.HasProtocol(inst)
        or not EyeOfTerrorDash.IsReady(inst)
        or inst:HasTag("playerghost")
        or (target == nil and not allow_point)
        or target == inst
        or (inst.replica.inventory ~= nil and inst.replica.inventory:GetActiveItem() ~= nil)
    then
        return nil
    end

    local rawpos = position
    if rawpos == nil and target ~= nil and target:IsValid() then
        rawpos = target:GetPosition()
    end
    if rawpos == nil then
        return nil
    end

    ConfigureEyeOfTerrorReticule(inst)
    return EyeOfTerrorDash.GetTargetPoint(inst, rawpos)
end

local function DaywalkerAimRightClickPicker(inst, target, position)
    if ACTIONS.KEI_DAYWALKER_CANCEL_AIM ~= nil
        and DaywalkerLeap.IsAiming(inst)
        and DaywalkerLeap.IsReady(inst)
        and not inst:HasTag("playerghost")
    then
        return inst.components.playeractionpicker:SortActionList({ ACTIONS.KEI_DAYWALKER_CANCEL_AIM }, position or inst:GetPosition())
    end
    local useitem = inst.replica.inventory ~= nil and inst.replica.inventory:GetActiveItem() or nil
    if useitem == nil then
        for _, action in ipairs(ClientSettings:GetRightClickPriority()) do
            if action == "guard" and CanUseRookGuard(inst) then
                return inst.components.playeractionpicker:SortActionList({ ACTIONS.KEI_ROOK_GUARD }, position or inst:GetPosition())
            elseif action == "leap"
                and ACTIONS.KEI_DAYWALKER_AIM ~= nil
                and DaywalkerLeap.HasProtocol(inst)
                and DaywalkerLeap.IsReady(inst)
                and not inst:HasTag("playerghost")
            then
                local targetpos = DaywalkerLeap.GetTargetPoint(inst, position)
                if targetpos ~= nil then
                    return inst.components.playeractionpicker:SortActionList({ ACTIONS.KEI_DAYWALKER_AIM }, targetpos)
                end
            elseif action == "dash" then
                local dashpos = GetRightClickDashPoint(inst, target, position)
                if dashpos ~= nil then
                    return inst.components.playeractionpicker:SortActionList({ ACTIONS.KEI_EYEOFTERROR_DASH }, dashpos)
                end
            end
        end
    end
    if inst._kei_old_rightclickoverride ~= nil then
        return inst._kei_old_rightclickoverride(inst, target, position)
    end
    return nil, true
end

local function OnSetOwner(inst)
    if inst.components.playeractionpicker ~= nil then
        if not inst._kei_daywalker_picker_wrapped then
            inst._kei_old_leftclickoverride = inst.components.playeractionpicker.leftclickoverride
            inst._kei_old_rightclickoverride = inst.components.playeractionpicker.rightclickoverride
            inst.components.playeractionpicker.leftclickoverride = DaywalkerAimLeftClickPicker
            inst.components.playeractionpicker.rightclickoverride = DaywalkerAimRightClickPicker
            inst._kei_daywalker_picker_wrapped = true
        end
        inst.components.playeractionpicker.pointspecialactionsfn = GetPointSpecialActions
    end
end

local function ConfigureVisuals(inst)
    -- 使用 Kei 自己的角色 build；角色 id、文件名和资源 build 统一为小写 kei。
    inst.AnimState:SetBuild("kei")
    inst.MiniMapEntity:SetIcon("kei.tex")
end

local function CreateKeiPowerBadge(owner)
    local KeiPowerBadge = require "widgets/kei_powerbadge"
    return KeiPowerBadge(owner)
end

local function CreateKeiStabilityBadge(owner)
    local KeiStabilityBadge = require "widgets/kei_stabilitybadge"
    return KeiStabilityBadge(owner)
end

local function CreateKeiIntegrityBadge(owner)
    local KeiIntegrityBadge = require "widgets/kei_integritybadge"
    return KeiIntegrityBadge(owner)
end

local function IsKeiSleeping(inst)
    if inst:HasTag("kei_dormant") or inst:HasTag("playerghost") then
        return true
    end
    if inst.components.health ~= nil and inst.components.health:IsDead() then
        return true
    end
    if inst.sg ~= nil then
        if inst.sg:HasStateTag("sleeping") or inst.sg:HasStateTag("yawn") then
            return true
        end
        if inst.sg.currentstate ~= nil and inst.sg.currentstate.name == "knockout" then
            return true
        end
    end
    return false
end

local function RemoveKeiPersonalLight(inst)
    if inst.kei_personal_light ~= nil then
        if inst.kei_personal_light:IsValid() then
            inst.kei_personal_light:Remove()
        end
        inst.kei_personal_light = nil
    end
end

local function CreateKeiPersonalLight(inst)
    if inst.kei_personal_light ~= nil and inst.kei_personal_light:IsValid() then
        return
    end

    local light = inst:SpawnChild("minerhatlight")
    if light == nil then
        return
    end

    light.Light:SetFalloff(KEI_LIGHT_FALLOFF)
    light.Light:SetIntensity(KEI_LIGHT_INTENSITY)
    light.Light:SetRadius(KEI_LIGHT_RADIUS)
    light.Light:SetColour(unpack(KEI_LIGHT_COLOUR))
    inst.kei_personal_light = light
end

local function UpdateKeiPersonalLight(inst)
    if IsKeiSleeping(inst) then
        RemoveKeiPersonalLight(inst)
    else
        CreateKeiPersonalLight(inst)
    end
end

local function PatchKeiChannelCastingFns(inst)
    if inst._kei_old_IsChannelCasting ~= nil then
        return
    end

    inst._kei_old_IsChannelCasting = inst.IsChannelCasting
    inst._kei_old_IsChannelCastingItem = inst.IsChannelCastingItem

    inst.IsChannelCasting = function(player, ...)
        return player.kei_mutatedwarg_channelcasting == true
            or (player._kei_old_IsChannelCasting ~= nil and player:_kei_old_IsChannelCasting(...))
            or false
    end

    inst.IsChannelCastingItem = function(player, ...)
        return player.kei_mutatedwarg_channelcasting == true
            or (player._kei_old_IsChannelCastingItem ~= nil and player:_kei_old_IsChannelCastingItem(...))
            or false
    end
end

local function PatchKeiCurseImmunity(inst)
    local cursable = inst.components.cursable
    if cursable == nil or cursable.kei_old_ApplyCurse ~= nil then
        return
    end

    -- yyxk uses character-side curse immunity by swallowing ApplyCurse.
    cursable.kei_old_ApplyCurse = cursable.ApplyCurse
    cursable.ApplyCurse = function()
    end
end

local UpdateDormantActionFilter

local function common_postinit(inst)
    KeiBackupBody.ConfigureCommon(inst)

    -- 标签用于动作过滤、专属配方解锁，以及电击免疫等基础设定。
    inst:AddTag("kei")
    -- Make the vanilla Wilson stategraph resolve hurt/talk/death sounds to
    -- the Kei address space instead of relying on the prefab fallback.
    inst.soundsname = "kei"
    inst:AddTag("electricdamageimmune")
    inst:AddTag("batteryuser")
    inst:AddTag(FOODTYPE.KEI_DEVICE .. "_eater")
    inst.CreateHungerBadge = CreateKeiPowerBadge
    inst.CreateSanityBadge = CreateKeiStabilityBadge
    inst.CreateHealthBadge = CreateKeiIntegrityBadge

    inst._kei_unlocked_protocol_slots = net_smallbyte(inst.GUID, "kei.unlocked_protocol_slots", "kei_protocol_slots_dirty")
    inst._kei_protocol_slot_visuals = {}
    for slot = 1, 7 do
        inst._kei_protocol_slot_visuals[slot] = net_string(
            inst.GUID,
            "kei.protocol_slot_visual_" .. tostring(slot),
            "kei_protocol_slot_visuals_dirty"
        )
    end
    inst._kei_mini_alice_pages = net_smallbyte(inst.GUID, "kei.mini_alice_pages", "kei_mini_alice_pages_dirty")
    inst._kei_analysis_armor_upgrade_level = net_smallbyte(inst.GUID, "kei.analysis_armor_upgrade_level", "kei_analysis_armor_upgrade_dirty")
    inst._kei_rotor_skill_mask = net_ushortint(inst.GUID, "kei.rotor_skill_mask", "kei_rotor_skills_dirty")
    inst._kei_rotor_collect_harvest = net_bool(inst.GUID, "kei.rotor_collect_harvest", "kei_rotor_skills_dirty")
    inst._kei_rotor_upgrade_signal = net_smallbyte(inst.GUID, "kei.rotor_upgrade_signal", "kei_rotor_upgrades_dirty")
    inst._kei_rotor_upgrade_mobility = net_smallbyte(inst.GUID, "kei.rotor_upgrade_mobility", "kei_rotor_upgrades_dirty")
    inst._kei_rotor_upgrade_battery = net_smallbyte(inst.GUID, "kei.rotor_upgrade_battery", "kei_rotor_upgrades_dirty")
    inst._kei_rotor_upgrade_power_reduction = net_smallbyte(inst.GUID, "kei.rotor_upgrade_power_reduction", "kei_rotor_upgrades_dirty")
    inst._kei_taskbook_records = net_string(inst.GUID, "kei.taskbook_records", "kei_taskbook_dirty")
    inst._kei_taskbook_implanted = net_string(inst.GUID, "kei.taskbook_implanted", "kei_taskbook_dirty")
    inst._kei_taskbook_tasks = net_string(inst.GUID, "kei.taskbook_tasks", "kei_taskbook_dirty")
    inst._kei_taskbook_completed_count = net_ushortint(inst.GUID, "kei.taskbook_completed_count", "kei_taskbook_dirty")
    inst._kei_experience_current = net_float(inst.GUID, "kei.experience_current", "kei_experience_dirty")
    inst._kei_experience_max = net_float(inst.GUID, "kei.experience_max", "kei_experience_dirty")
    inst._kei_experience_total = net_float(inst.GUID, "kei.experience_total", "kei_experience_dirty")
    inst._kei_status_attack = net_float(inst.GUID, "kei.status_attack", "kei_status_combat_dirty")
    inst._kei_status_defense = net_float(inst.GUID, "kei.status_defense", "kei_status_combat_dirty")
    inst._kei_status_attack_detail = net_string(inst.GUID, "kei.status_attack_detail", "kei_status_combat_dirty")
    inst._kei_status_defense_detail = net_string(inst.GUID, "kei.status_defense_detail", "kei_status_combat_dirty")
    inst._kei_virtual_staff_equipped = net_bool(inst.GUID, "kei.virtual_staff_equipped", "kei_virtual_staff_dirty")
    inst._kei_virtual_staff_on_cooldown = net_bool(inst.GUID, "kei.virtual_staff_on_cooldown", "kei_virtual_staff_cd_dirty")
    inst._kei_eyeofterror_protocol_active = net_bool(inst.GUID, "kei.eyeofterror_protocol_active", "kei_eyeofterror_protocol_dirty")
    inst._kei_eyeofterror_dash_on_cooldown = net_bool(inst.GUID, "kei.eyeofterror_dash_on_cooldown", "kei_eyeofterror_dash_cd_dirty")
    inst._kei_daywalker_protocol_active = net_bool(inst.GUID, "kei.daywalker_protocol_active", "kei_daywalker_protocol_dirty")
    inst._kei_water_walk_protocol_active = net_bool(inst.GUID, "kei.water_walk_protocol_active", "kei_water_walk_protocol_dirty")
    inst._kei_mutatedwarg_protocol_active = net_bool(inst.GUID, "kei.mutatedwarg_protocol_active", "kei_mutatedwarg_protocol_dirty")
    inst._kei_rook_protocol_active = net_bool(inst.GUID, "kei.rook_protocol_active", "kei_rook_protocol_dirty")
    inst._kei_rook_guard_on_cooldown = net_bool(inst.GUID, "kei.rook_guard_on_cooldown", "kei_rook_guard_cd_dirty")
    inst._kei_map_teleport_protocol_active = net_bool(inst.GUID, "kei.map_teleport_protocol_active", "kei_map_teleport_protocol_dirty")
    inst._kei_daywalker_aiming = net_bool(inst.GUID, "kei.daywalker_aiming", "kei_daywalker_aiming_dirty")
    inst._kei_daywalker_leap_on_cooldown = net_bool(inst.GUID, "kei.daywalker_leap_on_cooldown", "kei_daywalker_leap_cd_dirty")

    inst:ListenForEvent("kei_experience_dirty", function()
        inst:PushEvent("refreshcrafting")
    end)
    inst:ListenForEvent("kei_protocol_slots_dirty", function()
        inst:PushEvent("refreshcrafting")
    end)
    inst:ListenForEvent("kei_mini_alice_pages_dirty", function()
        inst:PushEvent("refreshcrafting")
    end)
    inst:ListenForEvent("kei_analysis_armor_upgrade_dirty", function()
        inst:PushEvent("refreshcrafting")
    end)
    inst:ListenForEvent("kei_rotor_skills_dirty", function()
        inst:PushEvent("refreshcrafting")
    end)
    inst:ListenForEvent("kei_rotor_upgrades_dirty", function()
        inst:PushEvent("refreshcrafting")
    end)

    inst:AddComponent("reticule")
    inst.components.reticule.ease = true
    inst.components.reticule.mouseenabled = true
    inst.components.reticule.twinstickcheckscheme = true
    inst.components.reticule.twinstickmode = 1
    ConfigureEyeOfTerrorReticule(inst)

    inst:ListenForEvent("setowner", OnSetOwner)
    inst:ListenForEvent("kei_daywalker_aiming_dirty", UpdateDaywalkerAimingReticule)
    inst:ListenForEvent("kei_daywalker_leap_cd_dirty", UpdateDaywalkerAimingReticule)
    inst:ListenForEvent("kei_water_walk_protocol_dirty", OnWaterWalkProtocolDirty)
    inst:DoTaskInTime(0, OnWaterWalkProtocolDirty)
    inst:DoPeriodicTask(0.25, UpdateDormantActionFilter)

    PatchKeiChannelCastingFns(inst)
    ConfigureVisuals(inst)
end

local function HandleKeiDeviceEat(inst, food)
    if food:HasTag("kei_battery") then
        PowerStat.ApplyBattery(inst)
        if inst.components.talker ~= nil then
            inst.components.talker:Say(STRINGS.CHARACTERS.KEI.ANNOUNCE_KEI_CHARGED)
        end
        return true
    elseif food:HasTag("kei_repair_tool") then
        IntegrityStat.ApplyRepair(inst)
        if inst.components.talker ~= nil then
            inst.components.talker:Say(STRINGS.CHARACTERS.KEI.ANNOUNCE_KEI_REPAIRED)
        end
        return true
    end
    return false
end

local function OnEat(inst, food)
    if food ~= nil and food.components.edible ~= nil then
        if food.components.edible.foodtype == FOODTYPE.KEI_DEVICE and HandleKeiDeviceEat(inst, food) then
            return
        end

        -- 饥饿值在原组件中会先完整结算，这里再扣回 80%，等价于只吸收 20%。
        local hunger = food.components.edible:GetHunger(inst) or 0
        local full = hunger
        local reduced = hunger * TUNING.KEI_FOOD_ABSORPTION
        if full ~= reduced and inst.components.hunger ~= nil then
            inst.components.hunger:DoDelta(reduced - full)
        end
    end
end

local function HasAlterguardianPowerOverride(inst)
    return inst.components.kei_protocolslots ~= nil
        and inst.components.kei_protocolslots:AlterguardianProtocolOverridesPower()
end

local function KeiDormantActionFilter(inst, action)
    return action == ACTIONS.KEI_WAKE
end

function UpdateDormantActionFilter(inst)
    local playeractionpicker = inst.components.playeractionpicker
    if playeractionpicker == nil then
        return
    end

    if inst:HasTag("kei_dormant") then
        if not inst.kei_dormant_action_filter_active then
            playeractionpicker:PushActionFilter(KeiDormantActionFilter, 999)
            inst.kei_dormant_action_filter_active = true
        end
    elseif inst.kei_dormant_action_filter_active then
        playeractionpicker:PopActionFilter(KeiDormantActionFilter)
        inst.kei_dormant_action_filter_active = nil
    end
end

local function SpawnDormantTransitionFx(inst)
    local x, y, z = inst.Transform:GetWorldPosition()
    local collapse = SpawnPrefab("collapse_small")
    if collapse ~= nil then
        collapse.Transform:SetPosition(x, y, z)
        if collapse.SetMaterial ~= nil then
            collapse:SetMaterial("metal")
        end
    end

    local spark = SpawnPrefab("wx78_big_spark")
    if spark ~= nil then
        if spark.AlignToTarget ~= nil then
            spark:AlignToTarget(inst)
        else
            spark.Transform:SetPosition(x, y, z)
        end
    end
    if inst.SoundEmitter ~= nil then
        inst.SoundEmitter:PlaySound("WX_rework/chassis/chassis_clunk")
    end
end

local function RestoreKeiDormantColour(inst)
    if inst.kei_dormant_old_multcolour ~= nil then
        inst.AnimState:SetMultColour(unpack(inst.kei_dormant_old_multcolour))
        inst.kei_dormant_old_multcolour = nil
    else
        inst.AnimState:SetMultColour(1, 1, 1, 1)
    end
end

local function RemoveDormantVisual(inst)
    if inst.kei_dormant_visual ~= nil then
        if inst.kei_dormant_visual:IsValid() then
            inst.kei_dormant_visual:Remove()
        end
        inst.kei_dormant_visual = nil
    end
end

local DORMANT_FACE_SYMBOLS = { "face", "swap_face", "cheeks" }

local function HideDormantFaceSymbols(visual)
    for _, symbol in ipairs(DORMANT_FACE_SYMBOLS) do
        visual.AnimState:HideSymbol(symbol)
    end
end

local function SetDormantChassisPose(visual)
    visual.AnimState:AddOverrideBuild("wx_chassis")
    visual.AnimState:PlayAnimation("wx_chassis_poweroff")
    visual.AnimState:SetPercent("wx_chassis_poweroff", 1)
    visual.AnimState:Pause()
    HideDormantFaceSymbols(visual)
end

local function CopyDormantVisualAppearance(owner, visual)
    if visual.components.skinner ~= nil and owner.components.skinner ~= nil then
        visual.components.skinner:CopySkinsFromPlayer(owner, true)
        SetDormantChassisPose(visual)
    end
end

local function SpawnDormantVisual(inst)
    RemoveDormantVisual(inst)

    local visual = SpawnPrefab("kei_dormant_chassis")
    if visual == nil then
        return
    end

    visual.entity:SetParent(inst.entity)
    visual.Transform:SetPosition(0, 0, 0)
    visual.Transform:SetRotation(0)
    visual.Transform:SetScale(1, 1, 1)
    CopyDormantVisualAppearance(inst, visual)
    inst.kei_dormant_visual = visual
end

local function ClearDormantAttackers(inst)
    local x, y, z = inst.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, 40, { "_combat" }, { "INLIMBO" })
    for _, ent in ipairs(ents) do
        if ent ~= inst and ent.components.combat ~= nil and ent.components.combat.target == inst then
            ent.components.combat:SetTarget(nil)
        end
    end
end

local function StopDormantBatteryCharge(inst)
    local node = inst.kei_dormant_charge_node
    if node ~= nil then
        if node:IsValid() then
            if node.components.circuitnode ~= nil then
                node.components.circuitnode:Disconnect()
            end
            node:Remove()
        end
        inst.kei_dormant_charge_node = nil
        inst.kei_dormant_charge_battery = nil
    end
end

local function CancelDormantZeroPowerExit(inst)
    if inst.kei_dormant_zero_power_exit_task ~= nil then
        inst.kei_dormant_zero_power_exit_task:Cancel()
        inst.kei_dormant_zero_power_exit_task = nil
    end
end

local function ScheduleDormantZeroPowerExit(inst)
    if inst.kei_dormant_zero_power_exit_task ~= nil then
        return
    end

    inst.kei_dormant_zero_power_exit_task = inst:DoTaskInTime(TUNING.KEI_DORMANT_ZERO_POWER_GRACE_TIME or 3, function(inst)
        inst.kei_dormant_zero_power_exit_task = nil
        if inst.kei_dormant_active
            and inst.components ~= nil
            and inst.components.hunger ~= nil
            and inst.components.hunger.current <= 0
        then
            inst:StopKeiDormant()
        end
    end)
end

local function IsDormantBatteryUsable(inst, battery)
    if battery == nil
        or not battery:IsValid()
        or battery:HasTag("burnt")
        or battery.components == nil
        or battery.components.circuitnode == nil
        or not battery.components.circuitnode:IsEnabled()
        or battery.components.fueled == nil
        or battery.components.fueled:IsEmpty()
        or (battery.IsOverloaded ~= nil and battery:IsOverloaded())
    then
        return false
    end

    if not battery.components.circuitnode.connectsacrossplatforms
        and battery:GetCurrentPlatform() ~= inst:GetCurrentPlatform()
    then
        return false
    end

    local range = battery.components.circuitnode.range or TUNING.WINONA_BATTERY_RANGE or 16
    return battery:GetDistanceSqToInst(inst) <= range * range
end

local function GetDormantBatteryChargeMultiplier(battery)
    -- Winona's high battery is the gem-powered generator. Keep the default
    -- multiplier for the ordinary battery and for compatible generators from
    -- other mods, so they retain the existing charging rate.
    return battery ~= nil
        and (battery.prefab == "winona_battery_high" or battery:HasTag("gemsocket"))
        and (TUNING.KEI_DORMANT_GEM_BATTERY_CHARGE_MULTIPLIER or 2)
        or 1
end

local function FindDormantChargeBattery(inst)
    local x, y, z = inst.Transform:GetWorldPosition()
    local range = TUNING.WINONA_BATTERY_RANGE or 16
    local selected = nil
    local selected_multiplier = 1
    local batteries = TheSim:FindEntities(x, y, z, range, { "engineeringbattery" }, { "INLIMBO", "burnt" })
    for _, battery in ipairs(batteries) do
        if IsDormantBatteryUsable(inst, battery) then
            local multiplier = GetDormantBatteryChargeMultiplier(battery)
            -- Select the highest available source. This makes a gem battery
            -- override ordinary generators when both are in range, while
            -- still falling back to an ordinary generator if the gem battery
            -- becomes empty, overloaded, disconnected, or out of range.
            if selected == nil or multiplier > selected_multiplier then
                selected = battery
                selected_multiplier = multiplier
            end
        end
    end
    return selected, selected_multiplier
end

local function CreateDormantChargeNode(inst)
    local node = CreateEntity()

    node.entity:SetCanSleep(false)
    node.persists = false

    node.entity:AddTransform()
    node:AddTag("CLASSIFIED")
    node:AddTag("NOCLICK")
    node:AddTag("engineeringbatterypowered")

    node:AddComponent("circuitnode")
    node.components.circuitnode:SetFootprint(0)
    node.components.circuitnode.connectsacrossplatforms = false
    node.components.circuitnode:ConnectTo(nil)

    node:AddComponent("powerload")
    node.components.powerload:SetLoad(3)
    node.kei_dormant_charge_multiplier = 1

    node.kei_owner = inst
    node.AddBatteryPower = function(node)
        local owner = node.kei_owner
        if owner == nil
            or not owner:IsValid()
            or not owner.kei_dormant_active
            or owner.components == nil
            or owner.components.hunger == nil
        then
            if owner ~= nil and owner.StopDormantBatteryCharge ~= nil then
                owner:StopDormantBatteryCharge()
            elseif node:IsValid() then
                node:Remove()
            end
            return
        end

        local hunger = owner.components.hunger
        local max_power = hunger.max or TUNING.KEI_MAX_POWER or 120
        if hunger.current >= max_power then
            owner:StopDormantBatteryCharge()
            return
        end

        local multiplier = node.kei_dormant_charge_multiplier or 1
        local delta = math.min(
            max_power - hunger.current,
            (TUNING.KEI_DORMANT_BATTERY_CHARGE_RATE or 3) * multiplier * 0.5
        )
        if delta > 0 then
            Recovery.ApplyHungerDelta(owner, delta, nil, true)
            if hunger.current > 0 then
                CancelDormantZeroPowerExit(owner)
            end
        end
        if hunger.current >= max_power then
            owner:StopDormantBatteryCharge()
        end
    end

    inst.kei_dormant_charge_node = node
    return node
end

local function UpdateDormantBatteryCharge(inst)
    local hunger = inst.components.hunger
    if hunger == nil or hunger.current >= (hunger.max or TUNING.KEI_MAX_POWER or 120) then
        StopDormantBatteryCharge(inst)
        return false
    end

    -- Re-scan every dormant tick so a higher-quality generator can take over
    -- immediately when it enters the range, and the lower-quality source can
    -- resume when the gem generator is no longer usable.
    local battery, multiplier = FindDormantChargeBattery(inst)
    if battery == nil then
        StopDormantBatteryCharge(inst)
        return false
    end

    local node = inst.kei_dormant_charge_node
    if node == nil or not node:IsValid() then
        node = CreateDormantChargeNode(inst)
    end
    node.Transform:SetPosition(inst.Transform:GetWorldPosition())
    node.kei_dormant_charge_multiplier = multiplier

    if inst.kei_dormant_charge_battery ~= battery or node.components.circuitnode.numnodes <= 0 then
        node.components.circuitnode:Disconnect()
        node.components.circuitnode:ConnectTo(nil)
        node.components.circuitnode:AddNode(battery)
        inst.kei_dormant_charge_battery = battery
        battery:PushEvent("engineeringcircuitchanged")
    end

    return true
end

local function DoDormantTick(inst)
    if not inst.kei_dormant_active
        or inst.components.health == nil
        or inst.components.health:IsDead()
        or inst.components.hunger == nil
    then
        if inst.StopKeiDormant ~= nil then
            inst:StopKeiDormant()
        end
        return
    end

    if inst.components.hunger.current <= 0 then
        UpdateDormantBatteryCharge(inst)
        ScheduleDormantZeroPowerExit(inst)
        return
    end

    CancelDormantZeroPowerExit(inst)
    ClearDormantAttackers(inst)
    UpdateDormantBatteryCharge(inst)

    local health = inst.components.health
    local sanity = inst.components.sanity
    local health_before = health.currenthealth or 0
    local sanity_before = sanity ~= nil and sanity.current or nil
    local needs_integrity = health_before < (health.maxhealth or TUNING.KEI_MAX_INTEGRITY)
    local needs_stability = sanity ~= nil and sanity_before < (sanity.max or TUNING.KEI_MAX_STABILITY)

    if not needs_integrity and not needs_stability then
        return
    end

    if needs_stability then
        Recovery.ApplySanityDelta(inst, TUNING.KEI_DORMANT_STABILITY_REGEN or 3)
    end
    if needs_integrity then
        Recovery.ApplyHealthDelta(
            inst,
            TUNING.KEI_DORMANT_INTEGRITY_REGEN or 3,
            true,
            "kei_dormant",
            true
        )
    end

    if (sanity ~= nil and sanity_before ~= nil and sanity.current > sanity_before)
        or (health.currenthealth or 0) > health_before
    then
        local power_drain = TUNING.KEI_DORMANT_POWER_DRAIN or 1
        local slots = inst.components.kei_protocolslots
        if slots ~= nil and slots.GetPowerDrainMultiplier ~= nil then
            power_drain = power_drain * slots:GetPowerDrainMultiplier()
        end
        inst.components.hunger:DoDelta(-power_drain, nil, true)
    end
end

local function StopDormantTask(inst)
    if inst.kei_dormant_task ~= nil then
        inst.kei_dormant_task:Cancel()
        inst.kei_dormant_task = nil
    end
end

local function StartKeiDormant(inst, playfx)
    if inst.kei_dormant_active
        or inst:HasTag("playerghost")
        or inst.components.health == nil
        or inst.components.health:IsDead()
    then
        return false
    end

    if inst.components.hunger == nil then
        return false
    end

    inst.kei_dormant_active = true
    inst:AddTag("kei_dormant")
    RemoveKeiPersonalLight(inst)
    inst:AddTag("notarget")
    inst:AddTag("noattack")
    inst:AddTag("NOBLOCK")
    if inst.components.kei_protocolslots ~= nil then
        inst.components.kei_protocolslots:DisableAllProtocols()
    end

    if inst.components.health ~= nil then
        if not inst.kei_dormant_old_invincible_saved then
            inst.kei_dormant_old_invincible = inst.components.health.invincible == true
            inst.kei_dormant_old_invincible_saved = true
        end
        inst.components.health:SetInvincible(true)
    end
    if inst.components.locomotor ~= nil then
        inst.components.locomotor:Stop()
        inst.components.locomotor:SetExternalSpeedMultiplier(inst, "kei_dormant", 0)
    end
    if inst.components.combat ~= nil then
        inst.components.combat:SetTarget(nil)
    end
    if inst.components.inventory ~= nil then
        inst.components.inventory:Hide()
        inst.components.inventory:CloseAllChestContainers()
    end
    inst.kei_daywalker_aiming = nil
    if inst._kei_daywalker_aiming ~= nil then
        inst._kei_daywalker_aiming:set(false)
    end
    ClearDormantAttackers(inst)

    inst.kei_dormant_old_multcolour = { inst.AnimState:GetMultColour() }
    inst.AnimState:SetMultColour(
        inst.kei_dormant_old_multcolour[1] or 1,
        inst.kei_dormant_old_multcolour[2] or 1,
        inst.kei_dormant_old_multcolour[3] or 1,
        0
    )
    SpawnDormantVisual(inst)
    if playfx ~= false then
        SpawnDormantTransitionFx(inst)
    end
    StopDormantTask(inst)
    inst.kei_dormant_task = inst:DoPeriodicTask(1, DoDormantTick, 1)
    if inst.components.hunger.current <= 0 then
        UpdateDormantBatteryCharge(inst)
        ScheduleDormantZeroPowerExit(inst)
    end
    UpdateDormantActionFilter(inst)

    return true
end

local function StopKeiDormant(inst, playfx)
    if not inst.kei_dormant_active then
        return false
    end

    CancelDormantZeroPowerExit(inst)
    StopDormantBatteryCharge(inst)
    StopDormantTask(inst)
    inst.kei_dormant_active = nil
    inst:RemoveTag("kei_dormant")
    UpdateKeiPersonalLight(inst)
    if inst.components.kei_protocolslots ~= nil then
        inst.components.kei_protocolslots:Refresh()
    end
    inst:RemoveTag("notarget")
    inst:RemoveTag("noattack")
    inst:RemoveTag("NOBLOCK")

    if inst.components.health ~= nil then
        inst.components.health:SetInvincible(inst.kei_dormant_old_invincible == true)
    end
    inst.kei_dormant_old_invincible = nil
    inst.kei_dormant_old_invincible_saved = nil
    if inst.components.locomotor ~= nil then
        inst.components.locomotor:RemoveExternalSpeedMultiplier(inst, "kei_dormant")
    end
    if inst.components.inventory ~= nil then
        inst.components.inventory:Show()
    end
    inst:ShowActions(true)
    if inst.components.playercontroller ~= nil then
        inst.components.playercontroller:EnableMapControls(true)
        inst.components.playercontroller:Enable(true)
    end

    RestoreKeiDormantColour(inst)
    RemoveDormantVisual(inst)
    if playfx ~= false then
        SpawnDormantTransitionFx(inst)
    end
    UpdateDormantActionFilter(inst)

    return true
end

local function UpdateResourceState(inst)
    if inst.components.health == nil or inst.components.hunger == nil or inst.components.locomotor == nil then
        return
    end
    if inst.components.health:IsDead() or inst.kei_dormant_active then
        return
    end

    PowerStat.UpdateNoPowerState(inst, HasAlterguardianPowerOverride(inst))
    IntegrityStat.UpdateState(inst)
end

local function OnSave(inst, data)
    if inst.components.kei_protocolslots ~= nil then
        data.kei_protocolslots = inst.components.kei_protocolslots:OnSave()
    end
    if inst.components.kei_experience ~= nil then
        data.kei_experience = inst.components.kei_experience:OnSave()
    end
    if inst.components["drone/skills"] ~= nil then
        data.kei_rotor_skills = inst.components["drone/skills"]:OnSave()
    end
    if inst.components["drone/upgrades"] ~= nil then
        data.kei_rotor_upgrades = inst.components["drone/upgrades"]:OnSave()
    end
    local controller_power = inst._kei_rotor_controller_power
    if controller_power == nil and inst.userid ~= nil then
        local controller = RotorSurveyRegistry.FindController(inst.userid)
        local power = controller ~= nil
            and controller.components ~= nil
            and controller.components["drone/power"]
            or nil
        if power ~= nil and power.GetPower ~= nil then
            controller_power = power:GetPower()
        end
    end
    if controller_power ~= nil then
        data.kei_rotor_controller_power = controller_power
    end
    if inst.components.kei_taskbook ~= nil then
        data.kei_taskbook = inst.components.kei_taskbook:OnSave()
    end
end

local function OnLoad(inst, data)
    if data ~= nil and data.kei_protocolslots ~= nil and inst.components.kei_protocolslots ~= nil then
        inst.components.kei_protocolslots:OnLoad(data.kei_protocolslots)
    end
    if data ~= nil and data.kei_experience ~= nil and inst.components.kei_experience ~= nil then
        inst.components.kei_experience:OnLoad(data.kei_experience)
    end
    if data ~= nil and data.kei_rotor_skills ~= nil and inst.components["drone/skills"] ~= nil then
        inst.components["drone/skills"]:OnLoad(data.kei_rotor_skills)
    end
    if data ~= nil and data.kei_rotor_upgrades ~= nil and inst.components["drone/upgrades"] ~= nil then
        inst.components["drone/upgrades"]:OnLoad(data.kei_rotor_upgrades)
    end
    if data ~= nil and data.kei_rotor_controller_power ~= nil then
        inst._kei_rotor_controller_power = tonumber(data.kei_rotor_controller_power)
    end
    if data ~= nil and data.kei_taskbook ~= nil and inst.components.kei_taskbook ~= nil then
        inst.components.kei_taskbook:OnLoad(data.kei_taskbook)
    end

    inst:DoTaskInTime(.1, function()
        local slots = inst.components.kei_protocolslots
        local taskbook = inst.components.kei_taskbook
        if slots ~= nil and taskbook ~= nil then
            for protocol in pairs(slots.implanted_combat_protocols or {}) do
                taskbook:MarkImplanted({ kind = "combat", protocol = protocol })
            end
            for _, protocol_data in ipairs(slots.implanted_basic_attributes or {}) do
                taskbook:MarkImplanted({ kind = "basic_attribute", protocol = protocol_data.protocol })
            end
        end
    end)

    ScheduleOpenMiniAlice(inst, 0.1)
    inst:DoTaskInTime(0, EnsureRotorSurveyController)
end

local function master_postinit(inst)
    ConfigureVisuals(inst)

    inst.starting_inventory = start_inv

    -- 用原版三维组件承载设计中的完整度 / 电量 / 稳定性。
    IntegrityStat.Configure(inst)
    PowerStat.Configure(inst)
    StabilityStat.Configure(inst)

    if inst.components.eater ~= nil then
        -- 禁用食物回血和回理智，仅保留食物转换为电量的路径。
        inst.components.eater:SetAbsorptionModifiers(0, 1, 0)
        inst.components.eater:SetCanEatGears()
        table.insert(inst.components.eater.caneat, FOODTYPE.KEI_DEVICE)
        table.insert(inst.components.eater.preferseating, FOODTYPE.KEI_DEVICE)
        inst.components.eater.cacheedibletags = nil
        inst.components.eater:SetOnEatFn(OnEat)
    end

    -- 协议槽负责扫描背包前 1/3/5/7 格中的协议 CD 并施加效果。
    inst:AddComponent("kei_protocolslots")
    inst:AddComponent("kei_experience")
    inst:AddComponent("drone/skills")
    inst:AddComponent("drone/upgrades")
    inst:AddComponent("kei_taskbook")

    -- The cycles world state increments exactly when a new day begins. The
    -- component records that value, so reconnects cannot create another batch.
    inst:WatchWorldState("cycles", function()
        if inst.components.kei_taskbook ~= nil then
            inst.components.kei_taskbook:RefreshDailyTasks()
        end
    end)
    inst:DoTaskInTime(0, function()
        if inst.components.kei_taskbook ~= nil then
            inst.components.kei_taskbook:RefreshDailyTasks()
        end
    end)

    PatchKeiCurseImmunity(inst)

    inst.StartKeiDormant = StartKeiDormant
    inst.StopKeiDormant = StopKeiDormant
    inst.StopDormantBatteryCharge = StopDormantBatteryCharge
    inst.CancelDormantZeroPowerExit = CancelDormantZeroPowerExit
    inst.ScheduleDormantZeroPowerExit = ScheduleDormantZeroPowerExit

    inst:DoPeriodicTask(TUNING.KEI_SELF_REPAIR_PERIOD, UpdateResourceState)
    inst:DoPeriodicTask(KEI_LIGHT_CHECK_PERIOD, UpdateKeiPersonalLight)
    inst:DoTaskInTime(0, UpdateKeiPersonalLight)
    inst:ListenForEvent("death", StopKeiDormant)
    inst:ListenForEvent("death", RemoveKeiPersonalLight)
    inst:ListenForEvent("onremove", StopKeiDormant)
    inst:ListenForEvent("onremove", RemoveKeiPersonalLight)

    KeiBackupBody.ConfigurePlayer(inst)
    ScheduleOpenMiniAlice(inst, 0.1)
    inst:DoTaskInTime(0, EnsureRotorSurveyController)

    -- 重进游戏或跨世界后，服务器会在玩家恢复完成时发送该事件。
    inst._kei_mini_alice_player_joined_fn = function(_, player)
        if player == inst then
            ScheduleOpenMiniAlice(inst, 0.1)
        end
    end
    inst:ListenForEvent("ms_playerjoined", inst._kei_mini_alice_player_joined_fn, TheWorld)
    inst:ListenForEvent("ms_respawnedfromghost", OnKeiRespawnedFromGhost)

    -- MakePlayerCharacter 会调用角色实例上的 OnSave / OnLoad 字段。
    inst._OnSave = OnSave
    inst._OnLoad = OnLoad
end

local function dormant_chassis_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    inst:AddTag("equipmentmodel")
    inst:AddTag("FX")
    inst:AddTag("NOCLICK")

    PlayerCommonExtensions.SetupBaseSymbolVisibility(inst)
    inst.AnimState:SetBank("wilson")
    inst.AnimState:SetBuild("wx78")
    SetDormantChassisPose(inst)
    inst.DynamicShadow:SetSize(1.3, 0.6)

    inst.AnimState:Hide("shad_veins")
    inst.AnimState:Hide("mimic1")
    inst.AnimState:Hide("mimic2")
    inst.AnimState:Hide("mimic3")
    inst.AnimState:Hide("trapper")
    inst.AnimState:Hide("gestalt_die")
    inst.AnimState:Hide("gestalt_flee")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    local skinner = inst:AddComponent("skinner")
    skinner:SetupNonPlayerData()
    skinner.useskintypeonload = true

    return inst
end

return MakePlayerCharacter("kei", prefabs, assets, common_postinit, master_postinit),
    Prefab("kei_dormant_chassis", dormant_chassis_fn, assets),
    Prefab("kei_backupbody", KeiBackupBody.MakePrefab, assets)
