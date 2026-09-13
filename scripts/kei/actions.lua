local CombatProtocolDefs = require("kei/protocols/combat")
local EyeOfTerrorDash = require("kei/protocols/combat/effects/beast/_eyeofterror_dash")
local DaywalkerLeap = require("kei/protocols/combat/effects/beast/_daywalker_leap")
local RookGuard = require("kei/protocols/combat/effects/biome/rook")
local PowerStat = require("kei/stats/power")
local IntegrityStat = require("kei/stats/integrity")
local SpDamageUtil = require("components/spdamageutil")
local SlowSources = require("kei/slow_sources")
local Enchantment = require("kei/integrations/enchantment")
local KeiEffectManager = require("kei/effect_manager")

local function AddKeiActionHandler(action, state)
    AddStategraphActionHandler("wilson", ActionHandler(action, state))
    AddStategraphActionHandler("wilson_client", ActionHandler(action, state))
end

local function GetSpellbookActionObject(act)
    return act ~= nil and (act.invobject or act.target) or nil
end

-- 为旋翼调查仪控制器使用专用的打开/关闭文本，不影响其他 spellbook。
local usespellbook_strfn = ACTIONS.USESPELLBOOK.strfn
ACTIONS.USESPELLBOOK.strfn = function(act)
    local object = GetSpellbookActionObject(act)
    if object ~= nil and object:HasTag("kei_rotor_survey_controller") then
        return "KEI_ROTOR_SURVEY_CONTROLLER"
    end
    return usespellbook_strfn ~= nil and usespellbook_strfn(act) or nil
end

local closespellbook_strfn = ACTIONS.CLOSESPELLBOOK.strfn
ACTIONS.CLOSESPELLBOOK.strfn = function(act)
    local object = GetSpellbookActionObject(act)
    if object ~= nil and object:HasTag("kei_rotor_survey_controller") then
        return "KEI_ROTOR_SURVEY_CONTROLLER"
    end
    return closespellbook_strfn ~= nil and closespellbook_strfn(act) or nil
end

-- 控制器使用独立的瞬时动作，并复用电刑机的控制动画。
-- 使用 inventoryitem 发现动作，避免 spellbook 组件在客户端动作列表同步时漏注册。
local ANALYSIS_BLACKLIST = {
    armorwagpunk = true,
    batnosehat = true,
    wagpunkhat = true,
    kei_rotor_surveyor = true,
    kei_rotor_survey_controller = true,
}

-- 需要兼容其他模组未加载的情况，因此这里只记录 prefab 名称，不主动
-- SpawnPrefab 或查询其他模组的物品定义。
local ANALYSIS_MOD_ITEM_BLACKLIST = {
    tbat_eq_shake_cup = true,
}

local RECORDER_STATE = {
    idle = 0,
    recording = 1,
    complete = 2,
}

local MAP_TELEPORT_DELAY = 12 * FRAMES
local MAP_TELEPORT_FINISH_DELAY = 12 * FRAMES
local MAP_TELEPORT_CANT_TAGS = { "INLIMBO", "NOCLICK", "FX" }

local function GetRecorderState(inst)
    if inst == nil then
        return RECORDER_STATE.idle
    end
    if inst._kei_recorder_state ~= nil then
        return inst._kei_recorder_state:value()
    end
    if inst.kei_state == "recording" then
        return RECORDER_STATE.recording
    elseif inst.kei_state == "complete" then
        return RECORDER_STATE.complete
    end
    return RECORDER_STATE.idle
end

-- 兼容可堆叠物品和单件物品的统一消耗函数。
local function ConsumeOne(item)
    if item == nil or not item:IsValid() then
        return
    end
    if item.components.stackable ~= nil then
        local one = item.components.stackable:Get()
        if one ~= nil then
            one:Remove()
        end
    else
        if item.components.inventoryitem ~= nil and item.components.inventoryitem.owner ~= nil then
            item.components.inventoryitem:RemoveFromOwner(true)
        end
        item:Remove()
    end
end

local function DeepCopyTable(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for k, v in pairs(value) do
        result[DeepCopyTable(k)] = DeepCopyTable(v)
    end
    return result
end

local function Say(doer, key)
    -- 所有提示都走 Kei 的角色语音表，避免在动作里散落硬编码文本。
    if doer ~= nil and doer.components.talker ~= nil and STRINGS.CHARACTERS.KEI[key] ~= nil then
        doer.components.talker:Say(STRINGS.CHARACTERS.KEI[key])
    end
end

local function IsKei(doer)
    return doer ~= nil and doer:HasTag("kei")
end

local function IsNonInteractiveFx(inst)
    return inst ~= nil
        and (inst:HasTag("FX")
            or inst:HasTag("NOCLICK")
            or inst:HasTag("DECOR"))
end

 

local function IsKeiMapTeleportBlocked(doer)
    return not IsKei(doer)
        or doer:HasTag("playerghost")
        or doer:HasTag("kei_dormant")
        or doer:HasTag("noteleport")
        or (doer.components.health ~= nil and doer.components.health:IsDead())
        or (doer.components.rider ~= nil and doer.components.rider:IsRiding())
        or (doer.components.inventory ~= nil and doer.components.inventory:IsHeavyLifting())
end

local function CastRotorControllerSpell(act)
    local controller = act.invobject or act.target
    if controller == nil
        or not controller:HasTag("kei_rotor_survey_controller")
        or controller.components.spellbook == nil
    then
        return false
    end

    -- 控制器必须已经装备在手部，避免存放在背包或娇小爱丽丝中时误触发轮盘。
    if controller.components.inventoryitem == nil
        or controller.components.inventoryitem:GetGrandOwner() ~= act.doer
        or controller.components.equippable == nil
        or not controller.components.equippable:IsEquipped()
    then
        return false
    end

    return controller.components.spellbook:CastSpell(act.doer)
end

local rotor_control_action = AddAction("KEI_ROTOR_CONTROL", "控制", CastRotorControllerSpell)
rotor_control_action.mount_valid = true

local rotor_pilot_action = AddAction("KEI_ROTOR_PILOT", "驾驶", CastRotorControllerSpell)
rotor_pilot_action.mount_valid = true

local rotor_beam_action = AddAction("KEI_ROTOR_BEAM", "光束", CastRotorControllerSpell)
rotor_beam_action.mount_valid = true

local function IsClearTeleportPoint(pt)
    local x, y, z = pt:Get()
    for _, ent in ipairs(TheSim:FindEntities(x, y, z, MAX_PHYSICS_RADIUS, nil, MAP_TELEPORT_CANT_TAGS)) do
        local radius = ent:GetPhysicsRadius(0)
        if radius > 0 and ent:GetDistanceSqToPoint(x, y, z) < radius * radius then
            return false
        end
    end
    return true
end

local function IsValidMapTeleportPoint(doer, pt)
    if doer == nil or pt == nil or TheWorld == nil or TheWorld.Map == nil then
        return false
    end

    local map = TheWorld.Map
    local x, y, z = pt:Get()
    local px, py, pz = doer.Transform:GetWorldPosition()

    if not IsTeleportingPermittedFromPointToPoint(px, py, pz, x, y, z) then
        return false
    end

    if map:GetPlatformAtPoint(x, z) ~= nil then
        return true
    end

    return map:IsPassableAtPoint(x, y, z)
        and not map:IsGroundTargetBlocked(pt)
        and IsClearTeleportPoint(pt)
end

local function StartKeiMapTeleport(doer, pt)
    if IsKeiMapTeleportBlocked(doer) or not IsValidMapTeleportPoint(doer, pt) then
        return false
    end

    doer.sg:GoToState("kei_map_teleport", pt)
    return true
end

local function GetAnalyzedWeaponDamage(target, doer)
    local weapon = target.components.weapon
    if weapon == nil then
        return 0
    end

    -- 远距离武器按攻击距离摊薄面板攻击力，避免解析后变成无代价高额近战加成。
    local damage = FunctionOrValue(weapon.damage, target, doer, nil) or 0
    local range = weapon.attackrange or 0
    if range >= 1 then
        damage = damage / range
    end
    return damage
end

local function GetAnalyzedToolData(target)
    local tool = target.components.tool
    if tool == nil then
        return nil
    end

    local actions = nil
    for action, effectiveness in pairs(tool.actions) do
        if action ~= nil and action.id ~= nil then
            actions = actions or {}
            -- 同一件工具如果暴露重复动作，也按效率叠加，和多协议叠加规则保持一致。
            actions[action.id] = (actions[action.id] or 0) + (effectiveness or 1)
        end
    end

    if actions == nil and not tool:CanDoToughWork() then
        return nil
    end

    return {
        actions = actions,
        tough = tool:CanDoToughWork() or nil,
    }
end

local function ToggleKeiOffPhysics(inst)
    inst.sg.statemem.isphysicstoggle = true
    inst.Physics:SetCollisionMask(COLLISION.GROUND)
end

local function ToggleKeiOnPhysics(inst)
    inst.sg.statemem.isphysicstoggle = nil
    inst.Physics:SetCollisionMask(
        COLLISION.WORLD,
        COLLISION.OBSTACLES,
        COLLISION.SMALLOBSTACLES,
        COLLISION.CHARACTERS,
        COLLISION.GIANTS
    )
end

local DASH_DAMAGE_MUST_TAGS = { "_combat" }
local DASH_DAMAGE_CANT_TAGS = { "INLIMBO", "wall", "companion", "flight", "invisible", "notarget", "noattack", "playerghost" }
local DASH_DAMAGE_SIDE_RANGE = 1
local DASH_DAMAGE_PHYSICS_PADDING = 3

local function GetEquippedWeapon(doer)
    return doer.components.inventory ~= nil and doer.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS) or nil
end

local function IsDashDamageTarget(doer, target)
    return target ~= doer
        and target:IsValid()
        and not target:IsInLimbo()
        and target.components.combat ~= nil
        and doer.components.combat ~= nil
        and doer.components.combat:IsValidTarget(target)
        and not (target.components.health ~= nil and target.components.health:IsDead())
end

local function HitDashTarget(doer, target, weapon)
    if not IsDashDamageTarget(doer, target) then
        return
    end

    local damage, spdamage = doer.components.combat:CalcDamage(target, weapon)
    damage = damage * 2
    spdamage = SpDamageUtil.ApplyMult(spdamage, 2)
    target.components.combat:GetAttacked(doer, damage, weapon, nil, spdamage)
end

local function DoEyeOfTerrorDashDamage(doer, startpt, endpt)
    if doer.components.combat == nil or startpt == nil or endpt == nil then
        return
    end

    local p1 = { x = startpt.x, y = startpt.z }
    local p2 = { x = endpt.x, y = endpt.z }
    local dx = p2.x - p1.x
    local dy = p2.y - p1.y
    local dist = dx * dx + dy * dy
    local weapon = GetEquippedWeapon(doer)
    local hit = {}
    local pv = {}

    if dist > 0 then
        dist = math.sqrt(dist)
        local radius = (dist + doer.components.combat.hitrange * 0.5 + DASH_DAMAGE_PHYSICS_PADDING) * 0.5
        dx = dx / dist
        dy = dy / dist
        local cx = p1.x + dx * radius
        local cz = p1.y + dy * radius

        local targets = TheSim:FindEntities(cx, 0, cz, radius, DASH_DAMAGE_MUST_TAGS, DASH_DAMAGE_CANT_TAGS)
        for _, target in ipairs(targets) do
            if IsDashDamageTarget(doer, target) then
                pv.x, pv._, pv.y = target.Transform:GetWorldPosition()
                local range = DASH_DAMAGE_SIDE_RANGE + target:GetPhysicsRadius(0.5)
                if DistPointToSegmentXYSq(pv, p1, p2) < range * range then
                    hit[target] = true
                    HitDashTarget(doer, target, weapon)
                end
            end
        end
    end

    local angle = (doer.Transform:GetRotation() + 90) * DEGREES
    local p3 = {
        x = p2.x + doer.components.combat.hitrange * math.sin(angle),
        y = p2.y + doer.components.combat.hitrange * math.cos(angle),
    }
    local targets = TheSim:FindEntities(p2.x, 0, p2.y, doer.components.combat.hitrange + DASH_DAMAGE_PHYSICS_PADDING, DASH_DAMAGE_MUST_TAGS, DASH_DAMAGE_CANT_TAGS)
    for _, target in ipairs(targets) do
        if not hit[target] and IsDashDamageTarget(doer, target) then
            pv.x, pv._, pv.y = target.Transform:GetWorldPosition()
            local radius = target:GetPhysicsRadius(0.5)
            local range = doer.components.combat.hitrange + radius
            if distsq(pv.x, pv.y, p2.x, p2.y) < range * range then
                range = DASH_DAMAGE_SIDE_RANGE + radius
                if DistPointToSegmentXYSq(pv, p2, p3) < range * range then
                    HitDashTarget(doer, target, weapon)
                end
            end
        end
    end
end

local function DoEyeOfTerrorDash(doer, targetpos)
    if not EyeOfTerrorDash.IsReady(doer) then
        return false
    end

    local pt = EyeOfTerrorDash.GetTargetPoint(doer, targetpos)
    if pt == nil then
        return false
    end

    local startpt = doer:GetPosition()
    doer:ForceFacePoint(pt)
    local fx = SpawnPrefab("spear_wathgrithr_lightning_lunge_fx")
    if fx ~= nil then
        fx.Transform:SetPosition(pt:Get())
        fx.Transform:SetRotation(doer:GetRotation())
    end
    if doer.SoundEmitter ~= nil then
        doer.SoundEmitter:PlaySound("meta3/wigfrid/spear_lighting_lunge")
    end

    if EyeOfTerrorDash.HasDamageProtocol(doer) then
        DoEyeOfTerrorDashDamage(doer, startpt, pt)
    end
    doer.Physics:Teleport(pt.x, 0, pt.z)

    doer.kei_eyeofterror_dash_on_cooldown = true
    if doer._kei_eyeofterror_dash_on_cooldown ~= nil then
        doer._kei_eyeofterror_dash_on_cooldown:set(true)
    end
    if doer._kei_eyeofterror_dash_cd_task ~= nil then
        doer._kei_eyeofterror_dash_cd_task:Cancel()
    end
    doer._kei_eyeofterror_dash_cd_task = doer:DoTaskInTime(TUNING.KEI_EYEOFTERROR_DASH_COOLDOWN or 1, function(inst)
        inst.kei_eyeofterror_dash_on_cooldown = nil
        inst._kei_eyeofterror_dash_cd_task = nil
        if inst._kei_eyeofterror_dash_on_cooldown ~= nil then
            inst._kei_eyeofterror_dash_on_cooldown:set(false)
        end
    end)

    return true
end

local function SetDaywalkerAiming(doer, aiming)
    if doer == nil then
        return
    end
    doer.kei_daywalker_aiming = aiming == true or nil
    if TheWorld.ismastersim and doer._kei_daywalker_aiming ~= nil then
        doer._kei_daywalker_aiming:set(aiming == true)
    end
end

local function StartDaywalkerLeapCooldown(doer)
    if doer == nil then
        return
    end

    SetDaywalkerAiming(doer, false)

    if not TheWorld.ismastersim then
        return
    end

    if doer.kei_daywalker_leap_cd_task ~= nil then
        doer.kei_daywalker_leap_cd_task:Cancel()
        doer.kei_daywalker_leap_cd_task = nil
    end

    doer.kei_daywalker_leap_on_cooldown = true
    if doer._kei_daywalker_leap_on_cooldown ~= nil then
        doer._kei_daywalker_leap_on_cooldown:set(true)
    end

    doer.kei_daywalker_leap_cd_task = doer:DoTaskInTime(TUNING.KEI_DAYWALKER_LEAP_COOLDOWN or 3, function(inst)
        inst.kei_daywalker_leap_on_cooldown = nil
        inst.kei_daywalker_leap_cd_task = nil
        if inst._kei_daywalker_leap_on_cooldown ~= nil then
            inst._kei_daywalker_leap_on_cooldown:set(false)
        end
    end)
end

local DAYWALKER_LEAP_MUST_TAGS = { "_combat" }
local DAYWALKER_LEAP_CANT_TAGS = { "INLIMBO", "wall", "companion", "flight", "invisible", "notarget", "noattack", "playerghost" }

local function SlowDaywalkerLeapTarget(target)
    if target.components.locomotor == nil then
        return
    end

    if not SlowSources.TryApply(
        target,
        "kei_daywalker_leap_slow",
        target,
        TUNING.KEI_DAYWALKER_LEAP_SLOW_MULT or 0.1
    ) then
        return
    end

    if target._kei_daywalker_leap_slow_task ~= nil then
        target._kei_daywalker_leap_slow_task:Cancel()
    end

    target._kei_daywalker_leap_slow_task = target:DoTaskInTime(TUNING.KEI_DAYWALKER_LEAP_SLOW_DURATION or 3, function(inst)
        SlowSources.Release(inst, "kei_daywalker_leap_slow", inst)
        inst._kei_daywalker_leap_slow_task = nil
    end)
end

local function SpawnDaywalkerLeapSinkhole(pos)
    local sinkhole = SpawnPrefab("daywalker_sinkhole")
    if sinkhole == nil then
        return
    end

    sinkhole.persists = false
    sinkhole.Transform:SetPosition(pos:Get())
    sinkhole:PushEvent("docollapse")
    sinkhole:DoTaskInTime(TUNING.KEI_DAYWALKER_SINKHOLE_DURATION or 3, function(inst)
        if inst:IsValid() then
            if ErodeAway ~= nil then
                ErodeAway(inst)
            else
                inst:Remove()
            end
        end
    end)
end

local function DoDaywalkerLeapImpact(doer, pos)
    if doer.components.combat == nil or pos == nil then
        return
    end

    SpawnDaywalkerLeapSinkhole(pos)

    local radius = TUNING.KEI_DAYWALKER_LEAP_RADIUS or 4
    local base_damage = TUNING.KEI_DAYWALKER_LEAP_DAMAGE_BASE or 150
    local advanced = DaywalkerLeap.HasAdvancedProtocol(doer)
    local maxhealth_percent = advanced and (TUNING.KEI_DAYWALKER_LEAP_DAMAGE_MAXHEALTH_PERCENT or 0.04) or 0
    local x, y, z = pos:Get()
    local targets = TheSim:FindEntities(x, y, z, radius, DAYWALKER_LEAP_MUST_TAGS, DAYWALKER_LEAP_CANT_TAGS)

    for _, target in ipairs(targets) do
        if target ~= doer
            and target:IsValid()
            and target.components.combat ~= nil
            and doer.components.combat:IsValidTarget(target)
            and not (target.components.health ~= nil and target.components.health:IsDead())
        then
            local maxhealth = target.components.health ~= nil and target.components.health.maxhealth or 0
            local damage = base_damage + maxhealth * maxhealth_percent
            target.components.combat:GetAttacked(doer, damage)
            if advanced then
                SlowDaywalkerLeapTarget(target)
            end
        end
    end
end

local function DoDaywalkerLeap(doer, targetpos)
    if not DaywalkerLeap.IsAiming(doer) or not DaywalkerLeap.IsReady(doer) then
        return false
    end
    local pt = DaywalkerLeap.GetTargetPoint(doer, targetpos)
    if pt == nil then
        return false
    end

    StartDaywalkerLeapCooldown(doer)
    doer:PushEvent("kei_daywalker_leap", { targetpos = pt })
    return true
end

-- 按 R 触发喷火：插入附身座狼协议后，右键自身即可持续喷火。
local flamethrower_action = AddAction("KEI_MUTATEDWARG_FLAMETHROWER", "喷火", function(act)
    if not IsKei(act.doer) or act.target ~= act.doer or act.doer:HasTag("playerghost") then
        return false
    end
    if act.doer.components.kei_protocolslots == nil
        or not act.doer.components.kei_protocolslots:HasCombatProtocol("mutatedwarg")
    then
        return false
    end
    if act.doer.kei_mutatedwarg_channelcasting == nil then
        act.doer.kei_mutatedwarg_channelcasting = true
    end
    return true
end)
flamethrower_action.mount_valid = false
flamethrower_action.rmb = true
flamethrower_action.distance = math.huge
flamethrower_action.priority = 3
AddStategraphActionHandler("wilson", ActionHandler(ACTIONS.KEI_MUTATEDWARG_FLAMETHROWER, "kei_mutatedwarg_flamethrower"))
AddStategraphActionHandler("wilson_client", ActionHandler(ACTIONS.KEI_MUTATEDWARG_FLAMETHROWER, "kei_mutatedwarg_flamethrower"))

AddComponentAction("SCENE", "inspectable", function(inst, doer, actions, right)
    if not right
        or not IsKei(doer)
        or inst ~= doer
        or doer:HasTag("playerghost")
    then
        return
    end
    if doer.components.kei_protocolslots == nil
        or not doer.components.kei_protocolslots:HasCombatProtocol("mutatedwarg")
    then
        return
    end
    if doer.kei_mutatedwarg_channelcasting == nil then
        table.insert(actions, ACTIONS.KEI_MUTATEDWARG_FLAMETHROWER)
        return
    end
end)

AddStategraphState("wilson", State{
    name = "kei_mutatedwarg_flamethrower",
    tags = { "doing", "nomorph", "nodangle" },

    onenter = function(inst)
        inst.AnimState:PlayAnimation("channelcast_idle_pre")
        inst.AnimState:PushAnimation("channelcast_idle", true)
        inst.sg:SetTimeout(TUNING.KEI_MUTATEDWARG_FLAMETHROWER_DURATION or 5)
    end,

    ontimeout = function(inst)
        inst.sg.statemem.finished = true
        inst.kei_mutatedwarg_channelcasting = nil
        inst.AnimState:PlayAnimation("channelcast_idle_pst")
    end,

    events =
    {
        EventHandler("animqueueover", function(inst)
            if inst.AnimState:AnimDone() then
                inst.sg:GoToState("idle")
            end
        end),
    },
})

AddStategraphState("wilson_client", State{
    name = "kei_mutatedwarg_flamethrower",
    tags = { "doing", "nodangle" },
    server_states = { "kei_mutatedwarg_flamethrower" },

    onenter = function(inst)
        inst.AnimState:PlayAnimation("channelcast_idle_pre")
        inst.AnimState:PushAnimation("channelcast_idle", true)
        inst.sg:SetTimeout(TUNING.KEI_MUTATEDWARG_FLAMETHROWER_DURATION or 5)
    end,

    ontimeout = function(inst)
        inst.sg.statemem.finished = true
        inst.kei_mutatedwarg_channelcasting = nil
        inst.AnimState:PlayAnimation("channelcast_idle_pst")
    end,

    events =
    {
        EventHandler("animqueueover", function(inst)
            if inst.AnimState:AnimDone() then
                inst.sg:GoToState("idle")
            end
        end),
    },
})

local function GetBlankCDBoundTarget(cd)
    if cd == nil then
        return nil
    end
    if cd.kei_bound_target ~= nil and cd.kei_bound_target:IsValid() then
        return cd.kei_bound_target
    end
    if cd.kei_bound_guid ~= nil then
        local target = Ents[cd.kei_bound_guid]
        if target ~= nil and target:IsValid() then
            cd.kei_bound_target = target
            return target
        end
    end
    return nil
end

local function GetCombatProtocolFromItem(item)
    if item == nil then
        return nil
    end

    -- 协议字段只在服务器实体上写入；客户端动作预览用 prefab 反查，保证右键动作能出现。
    if item.kei_combat_protocol ~= nil then
        return item.kei_combat_protocol
    end
    return CombatProtocolDefs.COMBAT_PROTOCOL_PREFABS ~= nil
        and CombatProtocolDefs.COMBAT_PROTOCOL_PREFABS[item.prefab]
        or nil
end

local function IsBlankCDReadyForNewBinding(cd)
    if cd == nil or not cd:HasTag("kei_blank_cd") then
        return false
    end
    if cd.kei_bound_prefab == nil then
        return true
    end

    local target = GetBlankCDBoundTarget(cd)
    local ready = target == nil or not target:IsValid()
    if ready and cd.ClearBoundTarget ~= nil then
        cd:ClearBoundTarget()
    end
    return ready
end

local function IsAnalysisBlacklisted(target)
    local prefab = target ~= nil and target.prefab or nil
    return prefab ~= nil
        and (ANALYSIS_BLACKLIST[prefab] == true or ANALYSIS_MOD_ITEM_BLACKLIST[prefab] == true)
end

local function IsPotentialAnalyzableEquipment(target)
    return target ~= nil
        and not IsAnalysisBlacklisted(target)
        and target.replica ~= nil
        and target.replica.equippable ~= nil
        and target.replica.stackable == nil
end

local function GetPrefabDisplayName(prefab)
    return prefab ~= nil and (STRINGS.NAMES[string.upper(prefab)] or prefab) or nil
end

local function GetTargetDisplayName(target)
    if target == nil then
        return nil
    end
    return target:GetDisplayName() or GetPrefabDisplayName(target.prefab)
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

local function GetTargetWorldAnim(target, slot)
    if target ~= nil and target.AnimState ~= nil then
        -- Equipment from other mods may use a custom idle animation. Read the
        -- actual current name before falling back to the common vanilla names.
        if target.AnimState.GetCurrentAnimationName ~= nil then
            local success, current = pcall(
                target.AnimState.GetCurrentAnimationName,
                target.AnimState
            )
            if success and type(current) == "string" and current ~= "" then
                return current
            end
        end

        for _, anim in ipairs(WORLD_ANIM_CANDIDATES) do
            if target.AnimState:IsCurrentAnimation(anim) then
                return anim
            end
        end
    end
    return slot == EQUIPSLOTS.HANDS and "idle" or "anim"
end

local function GetTargetSkinName(target)
    if target == nil or target.GetSkinName == nil then
        return nil
    end
    local success, skin_name = pcall(target.GetSkinName, target)
    return success and skin_name or nil
end

local function GetTargetSkinBuild(target)
    if target == nil or target.GetSkinBuild == nil then
        return nil
    end
    local success, skin_build = pcall(target.GetSkinBuild, target)
    return success and skin_build or nil
end

-- 右键电池：把电池转化为 Kei 的电量，也就是 hunger 组件。
local charge_action = AddAction("KEI_CHARGE", "充电", function(act)
    if not IsKei(act.doer) or act.invobject == nil then
        return false
    end
    if act.doer.components.hunger ~= nil then
        PowerStat.ApplyBattery(act.doer)
    end
    ConsumeOne(act.invobject)
    Say(act.doer, "ANNOUNCE_KEI_CHARGED")
    return true
end)
charge_action.mount_valid = true
charge_action.rmb = true
charge_action.priority = 2
AddKeiActionHandler(ACTIONS.KEI_CHARGE, "doshortaction")

local rotor_recharge_action = AddAction("KEI_RECHARGE_ROTOR", "充电", function(act)
    local controller = act.target
    if not IsKei(act.doer)
        or act.invobject == nil
        or controller == nil
        or not controller:HasTag("kei_rotor_survey_controller")
        or controller.components == nil
        or controller.components["drone/power"] == nil
    then
        return false
    end

    local power = controller.components["drone/power"]
    power:Recharge(PowerStat.GetBatteryRestoreAmount(power:GetMaxPower()))
    ConsumeOne(act.invobject)
    Say(act.doer, "ANNOUNCE_KEI_CHARGED")
    return true
end)
rotor_recharge_action.mount_valid = true
rotor_recharge_action.rmb = true
rotor_recharge_action.priority = 2
AddKeiActionHandler(ACTIONS.KEI_RECHARGE_ROTOR, "give")

-- 右键修理工具：恢复机体完整度，也就是 health 组件。
local repair_action = AddAction("KEI_REPAIR", "修复", function(act)
    if not IsKei(act.doer) or act.invobject == nil then
        return false
    end
    if act.doer.components.health ~= nil and not act.doer.components.health:IsDead() then
        act.doer.components.health:DoDelta(IntegrityStat.GetRepairAmount(act.doer), nil, "kei_repair_tool")
    end
    ConsumeOne(act.invobject)
    Say(act.doer, "ANNOUNCE_KEI_REPAIRED")
    return true
end)
repair_action.mount_valid = true
repair_action.rmb = true
repair_action.priority = 2
AddKeiActionHandler(ACTIONS.KEI_REPAIR, "doshortaction")

local dormant_action = AddAction("KEI_DORMANT", "休眠", function(act)
    if not IsKei(act.doer) or act.target ~= act.doer or act.doer.StartKeiDormant == nil then
        return false
    end
    return act.doer:StartKeiDormant(false)
end)
dormant_action.mount_valid = false
dormant_action.rmb = true
dormant_action.priority = 5
AddKeiActionHandler(ACTIONS.KEI_DORMANT, "kei_dormant_poweroff")

local wake_action = AddAction("KEI_WAKE", "唤醒", function(act)
    if not IsKei(act.doer) or act.target ~= act.doer or act.doer.StopKeiDormant == nil then
        return false
    end
    return act.doer:StopKeiDormant(false)
end)
wake_action.mount_valid = false
wake_action.rmb = true
wake_action.priority = 5
AddKeiActionHandler(ACTIONS.KEI_WAKE, "kei_dormant_poweron")

local map_teleport_action = AddAction("KEI_MAP_TELEPORT", "传送", function(act)
    local pt = act:GetActionPoint()
    return pt ~= nil and StartKeiMapTeleport(act.doer, pt) or false
end)
map_teleport_action.mount_valid = false
map_teleport_action.rmb = true
map_teleport_action.priority = HIGH_ACTION_PRIORITY
map_teleport_action.customarrivecheck = ArriveAnywhere
map_teleport_action.map_only = true
map_teleport_action.invalid_hold_action = true
map_teleport_action.maponly_checkvalidpos_fn = function(act)
    local pt = act:GetActionPoint()
    if IsKeiMapTeleportBlocked(act.doer) or not IsValidMapTeleportPoint(act.doer, pt) then
        return false
    end
    return true, nil, pt.x, pt.z, nil
end
AddKeiActionHandler(ACTIONS.KEI_MAP_TELEPORT, "kei_map_teleport_pre")

local function SetKeiDormantControls(inst, enabled)
    if inst.components.inventory ~= nil then
        if enabled then
            inst.components.inventory:Show()
        else
            inst.components.inventory:Hide()
            inst.components.inventory:CloseAllChestContainers()
        end
    end
    inst:ShowActions(enabled)
    if inst.components.playercontroller ~= nil then
        inst.components.playercontroller:EnableMapControls(enabled)
        inst.components.playercontroller:Enable(enabled)
        if not enabled then
            inst.components.playercontroller:RemotePausePrediction()
        end
    end
end

local function AddKeiChassisBuild(inst)
    if not inst.sg.mem.kei_chassis_build then
        inst.sg.mem.kei_chassis_build = true
        inst.AnimState:AddOverrideBuild("wx_chassis")
    end
end

local function ClearKeiChassisBuild(inst)
    inst.sg.mem.kei_chassis_build = nil
    inst.AnimState:ClearOverrideBuild("wx_chassis")
end

AddStategraphState("wilson", State{
    name = "kei_map_teleport_pre",
    tags = { "busy", "pausepredict", "nomorph" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        if not inst:PerformBufferedAction() then
            inst.sg:GoToState("idle")
        end
    end,
})

AddStategraphState("wilson_client", State{
    name = "kei_map_teleport_pre",
    tags = { "busy", "pausepredict", "nomorph" },
    server_states = { "kei_map_teleport_pre", "kei_map_teleport" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst:PerformPreviewBufferedAction()
        inst.sg:SetTimeout(2)
    end,

    onupdate = function(inst)
        if inst.sg:ServerStateMatches() then
            if inst.entity:FlattenMovementPrediction() then
                inst.sg:GoToState("idle", "noanim")
            end
        elseif inst.bufferedaction == nil then
            inst.sg:GoToState("idle")
        end
    end,

    ontimeout = function(inst)
        inst:ClearBufferedAction()
        inst.sg:GoToState("idle")
    end,
})

AddStategraphState("wilson", State{
    name = "kei_map_teleport",
    tags = { "busy", "nopredict", "nomorph", "noattack", "nointerrupt" },

    onenter = function(inst, targetpos)
        if targetpos == nil or not IsValidMapTeleportPoint(inst, targetpos) then
            inst.sg:GoToState("idle")
            return
        end

        local protocolslots = inst.components.kei_protocolslots
        local hunger = inst.components.hunger
        local teleport_power_cost = TUNING.KEI_MAP_TELEPORT_POWER_COST or 30
        local power_cost = teleport_power_cost
        if protocolslots ~= nil and protocolslots.GetPowerDrainMultiplier ~= nil then
            power_cost = power_cost * protocolslots:GetPowerDrainMultiplier()
        end
        if protocolslots == nil
            or not protocolslots:HasLifeProtocol("map_teleport")
            or hunger == nil
            or hunger.current < power_cost
        then
            inst.sg:GoToState("idle")
            return
        end

        hunger:DoDelta(-power_cost, nil, "kei_map_teleport")

        inst.sg.statemem.targetpos = targetpos
        inst.components.locomotor:Stop()
        inst:AddTag("notarget")
        if inst.components.health ~= nil then
            inst.components.health:SetInvincible(true)
        end
        if inst.DynamicShadow ~= nil then
            inst.DynamicShadow:Enable(false)
        end

        KeiEffectManager.Clear(inst, "teleport_start")

        local x, y, z = inst.Transform:GetWorldPosition()
        local fx = SpawnPrefab("hermitcrab_fx_med")
        if fx ~= nil then
            KeiEffectManager.Register(inst, fx)
            fx.Transform:SetPosition(x, y, z)
        end
        inst:Hide()
        if inst.ScreenFade ~= nil then
            inst:ScreenFade(false, 0.5)
        end

        inst.sg.statemem.teleport_task = inst:DoTaskInTime(MAP_TELEPORT_DELAY, function(inst)
            local pt = inst.sg.statemem.targetpos
            if pt == nil or not IsValidMapTeleportPoint(inst, pt) then
                inst.sg:GoToState("idle")
                return
            end

            local platform = TheWorld.Map:GetPlatformAtPoint(pt.x, pt.z)
            local x, y, z = pt:Get()
            if platform ~= nil then
                local _, py, _ = platform.Transform:GetWorldPosition()
                y = py
            end

            local arrival_fx = SpawnPrefab("hermitcrab_fx_med")
            if arrival_fx ~= nil then
                KeiEffectManager.Register(inst, arrival_fx)
                arrival_fx.Transform:SetPosition(x, y, z)
            end

            if inst.Physics ~= nil then
                inst.Physics:Teleport(x, y, z)
            else
                inst.Transform:SetPosition(x, y, z)
            end
            inst:PushEvent("teleport_move")
            if protocolslots ~= nil then
                protocolslots:ScheduleRefresh()
            end
            if inst.SnapCamera ~= nil then
                inst:SnapCamera()
            end
            if inst.ScreenFade ~= nil then
                inst:ScreenFade(true, 0.5)
            end

            inst.sg.statemem.finish_task = inst:DoTaskInTime(MAP_TELEPORT_FINISH_DELAY, function(inst)
                inst.sg:GoToState("idle")
            end)
        end)
    end,

    onexit = function(inst)
        if inst.sg.statemem.teleport_task ~= nil then
            inst.sg.statemem.teleport_task:Cancel()
            inst.sg.statemem.teleport_task = nil
        end
        if inst.sg.statemem.finish_task ~= nil then
            inst.sg.statemem.finish_task:Cancel()
            inst.sg.statemem.finish_task = nil
        end

        inst:RemoveTag("notarget")
        if inst.components.health ~= nil then
            inst.components.health:SetInvincible(false)
        end
        if inst.DynamicShadow ~= nil then
            inst.DynamicShadow:Enable(true)
        end
        inst:Show()
        if inst.ScreenFade ~= nil then
            inst:ScreenFade(true, 0.25)
        end
    end,
})

AddStategraphState("wilson", State{
    name = "kei_dormant_poweroff",
    tags = { "busy", "pausepredict", "notalking", "noattack" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.Transform:SetNoFaced()
        inst:AddTag("notarget")
        AddKeiChassisBuild(inst)
        inst.AnimState:PlayAnimation("wx_chassis_poweroff")
        SetKeiDormantControls(inst, false)
        if inst.components.talker ~= nil then
            inst.components.talker:ShutUp()
            inst.components.talker:IgnoreAll("kei_dormant")
        end
    end,

    timeline =
    {
        FrameEvent(0, function(inst) inst.SoundEmitter:PlaySound("WX_rework/chassis/internal_rumble") end),
        FrameEvent(16, function(inst) inst.SoundEmitter:PlaySound("rifts5/generic_metal/ratchet") end),
        FrameEvent(19, function(inst)
            inst.sg:AddStateTag("nointerrupt")
            if inst.components.health ~= nil then
                if not inst.kei_dormant_old_invincible_saved then
                    inst.kei_dormant_old_invincible = inst.components.health.invincible == true
                    inst.kei_dormant_old_invincible_saved = true
                end
                inst.components.health:SetInvincible(true)
            end
        end),
        FrameEvent(22, function(inst) inst.SoundEmitter:PlaySound("rifts5/generic_metal/clunk") end),
        FrameEvent(28, function(inst)
            inst.SoundEmitter:PlaySound("WX_rework/chassis/chassis_clunk")
        end),
        FrameEvent(60, function(inst)
            inst.sg.statemem.dormant_success = inst:PerformBufferedAction()
            if inst.sg.statemem.dormant_success and inst.SnapCamera ~= nil then
                inst:SnapCamera()
            end
            inst.sg:GoToState("idle")
        end),
    },

    onexit = function(inst)
        inst.Transform:SetFourFaced()
        ClearKeiChassisBuild(inst)
        if not inst.sg.statemem.dormant_success then
            inst:RemoveTag("notarget")
            if inst.components.health ~= nil then
                inst.components.health:SetInvincible(inst.kei_dormant_old_invincible == true)
            end
            inst.kei_dormant_old_invincible = nil
            inst.kei_dormant_old_invincible_saved = nil
            SetKeiDormantControls(inst, true)
        else
            inst:ShowActions(true)
            if inst.components.playercontroller ~= nil then
                inst.components.playercontroller:EnableMapControls(true)
                inst.components.playercontroller:Enable(true)
            end
            if inst.components.inventory ~= nil then
                inst.components.inventory:Hide()
                inst.components.inventory:CloseAllChestContainers()
            end
        end
        if inst.components.talker ~= nil then
            inst.components.talker:StopIgnoringAll("kei_dormant")
        end
    end,
})

AddStategraphState("wilson_client", State{
    name = "kei_dormant_poweroff",
    tags = { "busy", "pausepredict", "notalking", "noattack" },
    server_states = { "kei_dormant_poweroff" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.Transform:SetNoFaced()
        AddKeiChassisBuild(inst)
        inst.AnimState:PlayAnimation("wx_chassis_poweroff")
        inst:PerformPreviewBufferedAction()
        inst.sg:SetTimeout(3)
    end,

    onupdate = function(inst)
        if inst.sg:ServerStateMatches() then
            if inst.entity:FlattenMovementPrediction() then
                inst.sg:GoToState("idle", "noanim")
            end
        elseif inst.bufferedaction == nil then
            inst.sg:GoToState("idle")
        end
    end,

    ontimeout = function(inst)
        inst:ClearBufferedAction()
        inst.sg:GoToState("idle")
    end,

    onexit = function(inst)
        inst.Transform:SetFourFaced()
        ClearKeiChassisBuild(inst)
    end,
})

AddStategraphState("wilson", State{
    name = "kei_dormant_poweron",
    tags = { "busy", "nopredict", "notalking", "noattack", "nointerrupt" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.Transform:SetNoFaced()
        inst:AddTag("notarget")
        if not inst:PerformBufferedAction() then
            inst.sg:GoToState("idle")
            return
        end
        -- The standard wx_poweron state is the controllable player-body
        -- reboot animation used after transferring consciousness into a
        -- backup chassis. It is different from wx78_possessedbody.spawn.
        inst.sg:GoToState("wx_poweron", false)
    end,
})

AddStategraphState("wilson_client", State{
    name = "kei_dormant_poweron",
    tags = { "busy", "nopredict", "notalking", "noattack", "nointerrupt" },
    server_states = { "kei_dormant_poweron", "wx_poweron" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.Transform:SetNoFaced()
        inst:PerformPreviewBufferedAction()
        inst.sg:GoToState("wx_poweron", false)
    end,
})

local EYEOFTERROR_DASH_POST_ANIM_SPEED = 1

-- 克眼战斗数据：右键点地选择方向；初级只冲刺，高级冲刺会造成路径伤害。
local eyeofterror_dash_action = AddAction("KEI_EYEOFTERROR_DASH", "冲锋", function(act)
    if not IsKei(act.doer) or not EyeOfTerrorDash.HasProtocol(act.doer) or not EyeOfTerrorDash.IsReady(act.doer) then
        return false
    end
    local pt = act:GetActionPoint()
    return pt ~= nil and DoEyeOfTerrorDash(act.doer, pt) or false
end)
eyeofterror_dash_action.mount_valid = true
eyeofterror_dash_action.rmb = true
eyeofterror_dash_action.distance = math.huge
eyeofterror_dash_action.priority = 3
eyeofterror_dash_action.invalid_hold_action = true

AddKeiActionHandler(ACTIONS.KEI_EYEOFTERROR_DASH, "kei_eyeofterror_dash_pre")

AddStategraphState("wilson", State{
    name = "kei_eyeofterror_dash_pre",
    tags = { "aoe", "doing", "busy", "nointerrupt", "nomorph" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.AnimState:SetDeltaTimeMultiplier(EYEOFTERROR_DASH_POST_ANIM_SPEED)
        if inst:PerformBufferedAction() then
            inst.AnimState:PlayAnimation("lunge_pst")
            if inst.components.bloomer ~= nil then
                inst.components.bloomer:PushBloom("kei_eyeofterror_dash", "shaders/anim.ksh", -2)
            end
            if inst.components.colouradder ~= nil then
                inst.components.colouradder:PushColour("kei_eyeofterror_dash", 1, 0.2, 0.2, 0)
            end
        else
            inst.sg:GoToState("idle")
        end
    end,

    events =
    {
        EventHandler("animover", function(inst)
            if not inst.AnimState:AnimDone() then
                return
            end
            inst.sg:GoToState("idle")
        end),
    },

    onexit = function(inst)
        inst.AnimState:SetDeltaTimeMultiplier(1)
        if inst.components.bloomer ~= nil then
            inst.components.bloomer:PopBloom("kei_eyeofterror_dash")
        end
        if inst.components.colouradder ~= nil then
            inst.components.colouradder:PopColour("kei_eyeofterror_dash")
        end
    end,
})

AddStategraphState("wilson_client", State{
    name = "kei_eyeofterror_dash_pre",
    tags = { "doing", "busy", "nointerrupt" },
    server_states = { "kei_eyeofterror_dash_pre" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.AnimState:SetDeltaTimeMultiplier(EYEOFTERROR_DASH_POST_ANIM_SPEED)
        inst.AnimState:PlayAnimation("lunge_pst")
        inst:PerformPreviewBufferedAction()
        inst.sg:SetTimeout(2)
    end,

    onupdate = function(inst)
        if inst.sg:ServerStateMatches() then
            if inst.entity:FlattenMovementPrediction() then
                inst.sg:GoToState("idle", "noanim")
            end
        elseif inst.bufferedaction == nil then
            inst.sg:GoToState("idle")
        end
    end,

    ontimeout = function(inst)
        inst:ClearBufferedAction()
        inst.sg:GoToState("idle")
    end,

    onexit = function(inst)
        inst.AnimState:SetDeltaTimeMultiplier(1)
    end,
})


-- 发条战车战斗数据：鼠标未拿物品时右键任意位置进入短时格挡窗口；手部装备不会阻止触发。
local rook_guard_action = AddAction("KEI_ROOK_GUARD", "格挡", function(act)
    if not IsKei(act.doer)
        or not RookGuard.HasProtocol(act.doer)
        or not RookGuard.IsReady(act.doer)
    then
        return false
    end
    return true
end)
rook_guard_action.mount_valid = false
rook_guard_action.rmb = true
rook_guard_action.distance = math.huge
rook_guard_action.priority = 10
rook_guard_action.invalid_hold_action = true

AddKeiActionHandler(ACTIONS.KEI_ROOK_GUARD, "kei_rook_guard")

local ROOK_GUARD_ANIM_SPEED = 2

local function PlayRookGuardStart(inst)
    inst.AnimState:PlayAnimation("wx_defense_on_pre")
end

local function PlayRookGuardOpen(inst)
    inst.AnimState:PlayAnimation("wx_defense_on")
end

local function PlayRookGuardEnd(inst)
    inst.AnimState:PlayAnimation("wx_defense_off")
end

AddStategraphState("wilson", State{
    name = "kei_rook_guard",
    tags = { "doing", "busy", "nointerrupt", "nomorph", "notalking", "kei_rook_guard" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        if not inst:PerformBufferedAction() or not RookGuard.BeginGuard(inst) then
            inst.sg:GoToState("idle")
            return
        end
        inst.AnimState:SetDeltaTimeMultiplier(ROOK_GUARD_ANIM_SPEED)
        PlayRookGuardStart(inst)
        inst.sg:SetTimeout(3)
    end,

    events =
    {
        EventHandler("animover", function(inst)
            if not inst.AnimState:AnimDone() then
                return
            end
            if inst.AnimState:IsCurrentAnimation("wx_defense_on_pre") then
                PlayRookGuardOpen(inst)
            elseif inst.AnimState:IsCurrentAnimation("wx_defense_on") then
                inst.sg.statemem.guard_finished = true
                RookGuard.FinishGuard(inst)
                PlayRookGuardEnd(inst)
            else
                inst.sg.statemem.finished = true
                inst.sg:GoToState("idle")
            end
        end),
    },

    ontimeout = function(inst)
        inst.sg.statemem.finished = true
        RookGuard.FinishGuard(inst)
        inst.sg:GoToState("idle")
    end,

    onexit = function(inst)
        if not inst.sg.statemem.guard_finished and not inst.sg.statemem.finished then
            RookGuard.CancelGuard(inst, true)
        end
        inst.AnimState:SetDeltaTimeMultiplier(1)
    end,
})

AddStategraphState("wilson_client", State{
    name = "kei_rook_guard",
    tags = { "doing", "busy", "nointerrupt", "notalking", "kei_rook_guard" },
    server_states = { "kei_rook_guard" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.AnimState:SetDeltaTimeMultiplier(ROOK_GUARD_ANIM_SPEED)
        PlayRookGuardStart(inst)
        inst:PerformPreviewBufferedAction()
        inst.sg:SetTimeout(3)
    end,

    onupdate = function(inst)
        if inst.sg:ServerStateMatches() then
            if inst.entity:FlattenMovementPrediction() then
                inst.sg:GoToState("idle", "noanim")
            end
        elseif inst.bufferedaction == nil then
            inst.sg:GoToState("idle")
        end
    end,

    events =
    {
        EventHandler("animover", function(inst)
            if not inst.AnimState:AnimDone() then
                return
            end
            if inst.AnimState:IsCurrentAnimation("wx_defense_on_pre") then
                PlayRookGuardOpen(inst)
            elseif inst.AnimState:IsCurrentAnimation("wx_defense_on") then
                PlayRookGuardEnd(inst)
            else
                inst.sg:GoToState("idle")
            end
        end),
    },

    ontimeout = function(inst)
        inst:ClearBufferedAction()
        inst.sg:GoToState("idle")
    end,

    onexit = function(inst)
        inst:ClearBufferedAction()
        inst.AnimState:SetDeltaTimeMultiplier(1)
    end,
})
local daywalker_aim_action = AddAction("KEI_DAYWALKER_AIM", "选择跳劈", function(act)
    if not IsKei(act.doer) or not DaywalkerLeap.HasProtocol(act.doer) or not DaywalkerLeap.IsReady(act.doer) then
        return false
    end
    SetDaywalkerAiming(act.doer, true)
    return true
end)
daywalker_aim_action.mount_valid = true
daywalker_aim_action.rmb = true
daywalker_aim_action.distance = math.huge
daywalker_aim_action.priority = 4
daywalker_aim_action.invalid_hold_action = true

local daywalker_cancel_aim_action = AddAction("KEI_DAYWALKER_CANCEL_AIM", "取消跳劈", function(act)
    if not IsKei(act.doer) then
        return false
    end
    SetDaywalkerAiming(act.doer, false)
    return true
end)
daywalker_cancel_aim_action.mount_valid = true
daywalker_cancel_aim_action.rmb = true
daywalker_cancel_aim_action.distance = math.huge
daywalker_cancel_aim_action.priority = 4
daywalker_cancel_aim_action.invalid_hold_action = true

local daywalker_leap_action = AddAction("KEI_DAYWALKER_LEAP", "跳劈", function(act)
    if not IsKei(act.doer)
        or not DaywalkerLeap.HasProtocol(act.doer)
        or not DaywalkerLeap.IsAiming(act.doer)
        or not DaywalkerLeap.IsReady(act.doer)
    then
        return false
    end
    local pt = act:GetActionPoint()
    return pt ~= nil and DoDaywalkerLeap(act.doer, pt) or false
end)
daywalker_leap_action.mount_valid = true
daywalker_leap_action.distance = math.huge
daywalker_leap_action.priority = 4
daywalker_leap_action.invalid_hold_action = true

AddKeiActionHandler(ACTIONS.KEI_DAYWALKER_AIM, "kei_daywalker_aim")
AddKeiActionHandler(ACTIONS.KEI_DAYWALKER_CANCEL_AIM, "kei_daywalker_aim")
AddKeiActionHandler(ACTIONS.KEI_DAYWALKER_LEAP, "kei_daywalker_leap_pre")

local DAYWALKER_LEAP_PRE_ANIM_SPEED = 3
local DAYWALKER_LEAP_POST_ANIM_SPEED = 4

AddStategraphState("wilson", State{
    name = "kei_daywalker_aim",
    tags = { "doing" },

    onenter = function(inst)
        inst:PerformBufferedAction()
        inst.sg:GoToState("idle")
    end,
})

AddStategraphState("wilson_client", State{
    name = "kei_daywalker_aim",
    tags = { "doing" },
    server_states = { "kei_daywalker_aim" },

    onenter = function(inst)
        inst:PerformPreviewBufferedAction()
        inst.sg:GoToState("idle")
    end,
})

AddStategraphState("wilson", State{
    name = "kei_daywalker_leap_pre",
    tags = { "aoe", "doing", "busy", "nointerrupt", "nomorph" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.AnimState:SetDeltaTimeMultiplier(DAYWALKER_LEAP_PRE_ANIM_SPEED)
        inst.AnimState:PlayAnimation("atk_leap_pre")
    end,

    events =
    {
        EventHandler("kei_daywalker_leap", function(inst, data)
            inst.sg.statemem.leap = true
            inst.sg:GoToState("kei_daywalker_leap", data ~= nil and data.targetpos or nil)
        end),
        EventHandler("animover", function(inst)
            if not inst.AnimState:AnimDone() then
                return
            end
            if inst.AnimState:IsCurrentAnimation("atk_leap_pre") then
                inst.AnimState:PlayAnimation("atk_leap_lag")
                inst:PerformBufferedAction()
            else
                inst.sg:GoToState("idle")
            end
        end),
    },

    onexit = function(inst)
        inst.AnimState:SetDeltaTimeMultiplier(1)
    end,
})

AddStategraphState("wilson", State{
    name = "kei_daywalker_leap",
    tags = { "aoe", "doing", "busy", "nointerrupt", "nopredict", "nomorph" },

    onenter = function(inst, targetpos)
        if targetpos == nil or not inst.AnimState:IsCurrentAnimation("atk_leap_lag") then
            inst.sg:GoToState("idle", true)
            return
        end

        inst.AnimState:SetDeltaTimeMultiplier(1)
        ToggleKeiOffPhysics(inst)
        inst.Transform:SetEightFaced()
        inst.AnimState:PlayAnimation("atk_leap")
        inst.SoundEmitter:PlaySound("dontstarve/common/deathpoof")
        inst.sg.statemem.startingpos = inst:GetPosition()
        inst.sg.statemem.targetpos = targetpos

        if inst.sg.statemem.startingpos.x ~= targetpos.x or inst.sg.statemem.startingpos.z ~= targetpos.z then
            inst:ForceFacePoint(targetpos:Get())
            inst.Physics:SetMotorVel(math.sqrt(distsq(inst.sg.statemem.startingpos.x, inst.sg.statemem.startingpos.z, targetpos.x, targetpos.z)) / (12 * FRAMES), 0, 0)
        end
    end,

    timeline =
    {
        TimeEvent(12 * FRAMES, function(inst)
            ToggleKeiOnPhysics(inst)
            inst.Physics:Stop()
            inst.Physics:SetMotorVel(0, 0, 0)
            inst.Physics:Teleport(inst.sg.statemem.targetpos.x, 0, inst.sg.statemem.targetpos.z)
        end),
        TimeEvent(13 * FRAMES, function(inst)
            ShakeAllCameras(CAMERASHAKE.VERTICAL, 0.7, 0.015, 0.8, inst, 20)
            inst.sg:RemoveStateTag("nointerrupt")
            DoDaywalkerLeapImpact(inst, inst.sg.statemem.targetpos)
            inst.AnimState:SetDeltaTimeMultiplier(DAYWALKER_LEAP_POST_ANIM_SPEED)
        end),
    },

    events =
    {
        EventHandler("animover", function(inst)
            if inst.AnimState:AnimDone() then
                inst.sg:GoToState("idle")
            end
        end),
    },

    onexit = function(inst)
        if inst.sg.statemem.isphysicstoggle then
            ToggleKeiOnPhysics(inst)
            inst.Physics:Stop()
            inst.Physics:SetMotorVel(0, 0, 0)
            local x, y, z = inst.Transform:GetWorldPosition()
            if TheWorld.Map:IsPassableAtPoint(x, 0, z) and not TheWorld.Map:IsGroundTargetBlocked(Vector3(x, 0, z)) then
                inst.Physics:Teleport(x, 0, z)
            elseif inst.sg.statemem.targetpos ~= nil then
                inst.Physics:Teleport(inst.sg.statemem.targetpos.x, 0, inst.sg.statemem.targetpos.z)
            end
        end
        inst.AnimState:SetDeltaTimeMultiplier(1)
        inst.Transform:SetFourFaced()
    end,
})

AddStategraphState("wilson_client", State{
    name = "kei_daywalker_leap_pre",
    tags = { "doing", "busy", "nointerrupt" },
    server_states = { "kei_daywalker_leap_pre", "kei_daywalker_leap" },

    onenter = function(inst)
        inst.components.locomotor:Stop()
        inst.AnimState:SetDeltaTimeMultiplier(DAYWALKER_LEAP_PRE_ANIM_SPEED)
        inst.AnimState:PlayAnimation("atk_leap_pre")
        inst.AnimState:PushAnimation("atk_leap_lag", false)
        inst:PerformPreviewBufferedAction()
        inst.sg:SetTimeout(2)
    end,

    onupdate = function(inst)
        if inst.sg:ServerStateMatches() then
            if inst.entity:FlattenMovementPrediction() then
                inst.sg:GoToState("idle", "noanim")
            end
        elseif inst.bufferedaction == nil then
            inst.sg:GoToState("idle")
        end
    end,

    ontimeout = function(inst)
        inst:ClearBufferedAction()
        inst.sg:GoToState("idle")
    end,

    onexit = function(inst)
        inst.AnimState:SetDeltaTimeMultiplier(1)
    end,
})

-- 将初级巨兽协议 CD 交给数据记录器，延迟三秒召唤对应巨兽。
local submit_cd_action = AddAction("KEI_SUBMIT_CD", "提交记录", function(act)
    if not IsKei(act.doer) or act.target == nil or act.invobject == nil or act.target.StartKeiRecording == nil then
        return false
    end
    if CombatProtocolDefs.GetRecorderChallenge(GetCombatProtocolFromItem(act.invobject)) == nil then
        return false
    end
    return act.target:StartKeiRecording(act.invobject, act.doer)
end)
submit_cd_action.mount_valid = true
submit_cd_action.rmb = true
AddKeiActionHandler(ACTIONS.KEI_SUBMIT_CD, "give")

-- 记录中途取消会返还原本的初级巨兽协议 CD，记录仪回到 idle。
local stop_record_action = AddAction("KEI_STOP_RECORD", "停止记录", function(act)
    if not IsKei(act.doer) or act.target == nil or act.target.StopKeiRecording == nil then
        return false
    end
    return act.target:StopKeiRecording(act.doer)
end)
stop_record_action.mount_valid = true
stop_record_action.rmb = true
AddKeiActionHandler(ACTIONS.KEI_STOP_RECORD, "doshortaction")

-- 巨兽死亡后，从记录仪收获对应的战斗协议 CD。
local harvest_action = AddAction("KEI_HARVEST_RECORD", "收获数据", function(act)
    if not IsKei(act.doer) or act.target == nil or act.target.HarvestKeiData == nil then
        return false
    end
    return act.target:HarvestKeiData(act.doer)
end)
harvest_action.mount_valid = true
harvest_action.rmb = true
AddKeiActionHandler(ACTIONS.KEI_HARVEST_RECORD, "doshortaction")

-- 未激活的数据记录器可以空手右键收回为部署包。
local packup_record_action = AddAction("KEI_PACKUP_RECORDER", "收回", function(act)
    if not IsKei(act.doer) or act.target == nil or act.target.PackUpKeiRecorder == nil then
        return false
    end
    return act.target:PackUpKeiRecorder(act.doer)
end)
packup_record_action.mount_valid = true
packup_record_action.rmb = true
AddKeiActionHandler(ACTIONS.KEI_PACKUP_RECORDER, "doshortaction")

local function GiveCopiedCD(doer, cd)
    if cd == nil then
        return false
    end

    if doer.components.inventory ~= nil then
        doer.components.inventory:GiveItem(cd, nil, doer:GetPosition())
    else
        cd.Transform:SetPosition(doer.Transform:GetWorldPosition())
    end
    return true
end

local function CopyProtocolCD(material, target, doer)
    if TUNING.KEI_ALLOW_DATA_COPY == false or material == nil or target == nil then
        return false
    end

    local cd = nil
    if material:HasTag("kei_blank_cd")
        and IsBlankCDReadyForNewBinding(material)
        and target:HasTag("kei_combat_protocol")
    then
        local protocol = target.kei_combat_protocol
            or (target.kei_protocol_data ~= nil and target.kei_protocol_data.protocol or nil)
        if protocol == nil then
            return false
        end
        local cd_prefab = CombatProtocolDefs.GetProtocolPrefab(protocol)
        cd = cd_prefab ~= nil and SpawnPrefab(cd_prefab) or nil
    elseif material:HasTag("kei_analysis_tool")
        and target:HasTag("kei_analysis_protocol")
        and target.kei_protocol_data ~= nil
        and target.kei_protocol_data.kind == "analysis"
    then
        cd = SpawnPrefab("kei_analysis_cd")
        if cd ~= nil then
            if cd:SetAnalysisData(DeepCopyTable(target.kei_protocol_data)) == false then
                cd = nil
            end
        end
    end

    if cd == nil then
        return false
    end

    if not GiveCopiedCD(doer, cd) then
        cd:Remove()
        return false
    end

    ConsumeOne(material)
    Say(doer, "ANNOUNCE_KEI_COPY_DONE")
    return true
end

local copy_cd_action = AddAction("KEI_COPY_DATA_CD", "拷贝数据", function(act)
    if not IsKei(act.doer) or act.invobject == nil or act.target == nil then
        return false
    end
    return CopyProtocolCD(act.invobject, act.target, act.doer)
end)
copy_cd_action.mount_valid = true
copy_cd_action.rmb = true
AddKeiActionHandler(ACTIONS.KEI_COPY_DATA_CD, "give")

local function AnalyzeEquipment(tool, target, doer)
    if IsAnalysisBlacklisted(target) then
        return false, false
    end

    -- 只解析不可堆叠的可装备物品；容器类物品即使可检查也不生成协议。
    if target.components.container ~= nil then
        return false, false
    end
    if target.components.stackable ~= nil then
        return false, false
    end
    if target.components.equippable == nil then
        return false, false
    end

    local slot = target.components.equippable.equipslot
    if slot == nil then
        return false, false
    end

    local inventoryitem = target.components.inventoryitem
    local data = {
        source = target.prefab,
        display_name = GetTargetDisplayName(target),
        icon_image = inventoryitem ~= nil and (inventoryitem.imagename or target.prefab) or target.prefab,
        icon_atlas = inventoryitem ~= nil and inventoryitem.atlasname or nil,
        visual_bank = target.AnimState ~= nil and target.AnimState:GetBankHash() or nil,
        visual_build = target.AnimState ~= nil and target.AnimState:GetBuild() or nil,
        visual_anim = GetTargetWorldAnim(target, slot),
        skin_name = GetTargetSkinName(target),
        skin_build = GetTargetSkinBuild(target),
        full_equipment = true,
        enchantments = Enchantment.Capture(target),
    }

    -- 头部和身体装备提取护甲吸收率；手部装备提取武器、移速和平面伤害信息。
    -- 装备栏扩展 mod 通常仍使用原版 equippable，只把 equipslot 改成自定义值。
    -- 因此未知的非手部槽位统一按身体类装备解析，避免把具体槽位名称硬编码进来。
    if slot == EQUIPSLOTS.HEAD then
        data.kind = "analysis"
        data.slot = "head"
        data.absorb = target.components.armor ~= nil and target.components.armor.absorb_percent or 0
    elseif slot == EQUIPSLOTS.HANDS then
        data.kind = "analysis"
        data.slot = "hands"
        local tooldata = GetAnalyzedToolData(target)
        data.damage_bonus = GetAnalyzedWeaponDamage(target, doer)
        data.speed_mult = target.components.equippable.walkspeedmult or 1
        data.planar_bonus = target.components.planardamage ~= nil and target.components.planardamage:GetDamage() or 0
        data.tool_actions = tooldata ~= nil and tooldata.actions or nil
        data.tool_tough = tooldata ~= nil and tooldata.tough or nil
    else
        -- BODY 以及 BELLY/NECK/BACK 等扩展槽都走护甲类协议的虚拟装备路径。
        data.kind = "analysis"
        data.slot = "body"
        data.absorb = target.components.armor ~= nil and target.components.armor.absorb_percent or 0
    end

    local cd = SpawnPrefab("kei_analysis_cd")
    if cd == nil then
        return false, false
    end
    -- 解析结果写入新生成的 CD，协议槽组件会在背包中读取这些数据。
    if cd:SetAnalysisData(data) == false then
        cd:Remove()
        return false, false
    end
    if doer.components.inventory ~= nil then
        doer.components.inventory:GiveItem(cd, nil, doer:GetPosition())
    else
        cd.Transform:SetPosition(doer.Transform:GetWorldPosition())
    end
    ConsumeOne(tool)
    if TUNING.KEI_ANALYSIS_CONSUME_EQUIPMENT then
        ConsumeOne(target)
    end
    Say(doer, "ANNOUNCE_KEI_ANALYSIS_DONE")
    return true
end

-- 用解析工具点装备，生成可插入协议槽的解析 CD。
local analyze_action = AddAction("KEI_ANALYZE_EQUIP", "解析装备", function(act)
    if not IsKei(act.doer) or act.invobject == nil or act.target == nil then
        return false
    end
    local success, consume_on_fail = AnalyzeEquipment(act.invobject, act.target, act.doer)
    if success then
        return true
    end
    Say(act.doer, "ANNOUNCE_KEI_ANALYSIS_FAILED")
    if consume_on_fail ~= false then
        ConsumeOne(act.invobject)
    end
    return false
end)
analyze_action.mount_valid = true
-- 解析工具对可解析装备的右键操作应优先于其他 Mod 常见的 GIVE、
-- 喂食或自定义交互动作；否则这些动作可能在 USEITEM 排序时抢先执行。
analyze_action.rmb = true
analyze_action.priority = HIGH_ACTION_PRIORITY
AddKeiActionHandler(ACTIONS.KEI_ANALYZE_EQUIP, "give")

-- USEITEM：拿着某个物品点另一个目标时添加动作，例如 CD -> 记录仪、解析工具 -> 装备。
AddComponentAction("USEITEM", "inventoryitem", function(inst, doer, target, actions, right)
    if not right or not IsKei(doer) or target == nil then
        return
    end
    if inst:HasTag("kei_battery")
        and target:HasTag("kei_rotor_survey_controller")
    then
        table.insert(actions, ACTIONS.KEI_RECHARGE_ROTOR)
    elseif target:HasTag("kei_data_recorder")
        and CombatProtocolDefs.GetRecorderChallenge(GetCombatProtocolFromItem(inst)) ~= nil
    then
        table.insert(actions, ACTIONS.KEI_SUBMIT_CD)
    elseif TUNING.KEI_ALLOW_DATA_COPY ~= false
        and inst:HasTag("kei_blank_cd")
        and IsBlankCDReadyForNewBinding(inst)
        and target:HasTag("kei_combat_protocol")
    then
        table.insert(actions, ACTIONS.KEI_COPY_DATA_CD)
    elseif TUNING.KEI_ALLOW_DATA_COPY ~= false
        and inst:HasTag("kei_analysis_tool")
        and target:HasTag("kei_analysis_protocol")
    then
        table.insert(actions, ACTIONS.KEI_COPY_DATA_CD)
    elseif inst:HasTag("kei_analysis_tool") and IsPotentialAnalyzableEquipment(target) then
        table.insert(actions, ACTIONS.KEI_ANALYZE_EQUIP)
    end
end)

-- SCENE：空手右键记录仪，根据状态显示停止记录或收获数据。
AddComponentAction("SCENE", "inspectable", function(inst, doer, actions, right)
    if not right or not IsKei(doer) or IsNonInteractiveFx(inst) then
        return
    end

    if inst == doer and not doer:HasTag("playerghost") then
        local activeitem = doer.replica.inventory ~= nil and doer.replica.inventory:GetActiveItem() or nil
        if activeitem == nil then
            if ACTIONS.KEI_ROOK_GUARD ~= nil
                and not doer:HasTag("kei_dormant")
                and RookGuard.HasProtocol(doer)
                and RookGuard.IsReady(doer)
            then
                table.insert(actions, ACTIONS.KEI_ROOK_GUARD)
            end
            table.insert(actions, doer:HasTag("kei_dormant") and ACTIONS.KEI_WAKE or ACTIONS.KEI_DORMANT)
        end
        return
    end

    if not inst:HasTag("kei_data_recorder") then
        return
    end

    local state = GetRecorderState(inst)
    if state == RECORDER_STATE.recording then
        table.insert(actions, ACTIONS.KEI_STOP_RECORD)
    elseif state == RECORDER_STATE.complete then
        table.insert(actions, ACTIONS.KEI_HARVEST_RECORD)
    elseif state == RECORDER_STATE.idle then
        local activeitem = doer.replica.inventory ~= nil and doer.replica.inventory:GetActiveItem() or nil
        if activeitem == nil and not inst:HasTag("NOCLICK") then
            table.insert(actions, ACTIONS.KEI_PACKUP_RECORDER)
        end
    end
end)

-- 空手时让解析协议继承的工具标签参与原版工作动作发现，支持空格自动捕捉等行为。
AddComponentAction("SCENE", "workable", function(inst, doer, actions, right)
    if not IsKei(doer) then
        return
    end

    if doer.replica.inventory ~= nil and doer.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS) ~= nil then
        return
    end

    for action_id in pairs(TOOLACTIONS) do
        local action = ACTIONS[action_id]
        if action ~= nil
            and doer:HasTag(action.id .. "_tool")
            and inst:IsActionValid(action, right)
            and (not right or action.rmb or not inst:HasTag("smolder"))
        then
            table.insert(actions, action)
            return
        end
    end
end)

AddComponentAction("SCENE", "portablestructure", function(inst, doer, actions, right)
    if not right
        or not IsKei(doer)
        or not inst:HasTag("engineering")
        or inst:HasTag("burnt")
        or (inst:HasTag("fire") and not inst:HasTag("campfire"))
    then
        return
    end

    if inst.candismantle ~= nil and not inst:candismantle(doer) then
        return
    end

    local container = inst.replica ~= nil and inst.replica.container or nil
    if container ~= nil and (not container:CanBeOpened() or container:IsOpenedBy(doer)) then
        return
    end

    table.insert(actions, ACTIONS.DISMANTLE)
end)
