-- 战争瓦器人协议：轨道打击光束 + 目标标记 FX。

local BeastCommon = require("kei/protocols/combat/effects/beast/_beast_common")
local KeiEffectManager = require("kei/effect_manager")
local WAGBOSS_TARGET_FOLLOW_PERIOD = FRAMES

local function IsValidBeamTarget(owner, target)
    return owner ~= nil
        and owner:IsValid()
        and owner.components.combat ~= nil
        and target ~= nil
        and target:IsValid()
        and not target:IsInLimbo()
        and target.entity:IsVisible()
        and target.components.health ~= nil
        and not target.components.health:IsDead()
        and target.components.combat ~= nil
        and owner.components.combat:CanTarget(target)
        and not owner.components.combat:IsAlly(target)
end

local WagbossEffect = {}

-- ---------- 目标标记 FX ----------

local function PositionTargetFx(slots)
    local fx = slots._kei_wagboss_target_fx
    if fx ~= nil and fx:IsValid() then
        fx.Transform:SetPosition(slots.inst.Transform:GetWorldPosition())
        fx.Transform:SetRotation(0)
    end
end

local function EnableTargetFx(slots, inst)
    if slots._kei_wagboss_target_fx ~= nil and slots._kei_wagboss_target_fx:IsValid() then
        return
    end

    local fx = SpawnPrefab("kei_wagboss_target_fx")
    if fx ~= nil then
        slots._kei_wagboss_target_fx = fx
        KeiEffectManager.Register(inst, fx, "wagboss_target", function()
            slots._kei_wagboss_target_fx = nil
            slots._kei_wagboss_target_follow_task = nil
        end)
        PositionTargetFx(slots)
        slots._kei_wagboss_target_follow_task = inst:DoPeriodicTask(WAGBOSS_TARGET_FOLLOW_PERIOD, function()
            PositionTargetFx(slots)
        end)
        KeiEffectManager.SetTask(inst, "wagboss_target", slots._kei_wagboss_target_follow_task)
    end
end

local function DisableTargetFx(slots)
    if slots._kei_wagboss_target_ready_task ~= nil then
        slots._kei_wagboss_target_ready_task:Cancel()
        slots._kei_wagboss_target_ready_task = nil
    end
    KeiEffectManager.Release(slots.inst, "wagboss_target_ready", "target_disable")
    if slots._kei_wagboss_target_follow_task ~= nil then
        slots._kei_wagboss_target_follow_task:Cancel()
        slots._kei_wagboss_target_follow_task = nil
    end
    if slots._kei_wagboss_target_fx ~= nil then
        if slots._kei_wagboss_target_fx:IsValid() then
            slots._kei_wagboss_target_fx:Remove()
        end
        slots._kei_wagboss_target_fx = nil
    end
end

local function RefreshTargetFx(slots, inst)
    if not BeastCommon.HasProtocol(slots, "wagboss_robot") then
        DisableTargetFx(slots)
        return
    end

    local now = GetTime()
    local ready_time = slots._kei_wagboss_beam_ready_time or 0
    if ready_time > now then
        DisableTargetFx(slots)
        slots._kei_wagboss_target_ready_task = inst:DoTaskInTime(ready_time - now, function()
            slots._kei_wagboss_target_ready_task = nil
            KeiEffectManager.Release(inst, "wagboss_target_ready", "task_complete")
            RefreshTargetFx(slots, inst)
        end)
        KeiEffectManager.RegisterTask(inst, slots._kei_wagboss_target_ready_task, "wagboss_target_ready", function()
            slots._kei_wagboss_target_ready_task = nil
        end)
        return
    end

    EnableTargetFx(slots, inst)
end

-- ---------- 接口方法 ----------

function WagbossEffect.Enable(slots, inst)
    RefreshTargetFx(slots, inst)
end

-- 关闭协议效果，并清理启用时注册的持续能力。
function WagbossEffect.Disable(slots, inst)
    DisableTargetFx(slots)
end

-- 处理攻击命中事件，根据协议等级触发附加战斗效果。
function WagbossEffect.OnHitOther(slots, inst, data)
    local target = data and data.target
    local now = GetTime()
    if (slots._kei_wagboss_beam_ready_time or 0) > now
        or not IsValidBeamTarget(inst, target)
    then
        return
    end

    local beam = SpawnPrefab("kei_wagboss_beam_fx")
    if beam == nil or beam.TrackTarget == nil then
        if beam ~= nil then
            beam:Remove()
        end
        return
    end

    local x, _, z = inst.Transform:GetWorldPosition()
    beam:SetCaster(inst)
    beam:TrackTarget(target, x, z)
    slots._kei_wagboss_beam_ready_time = now + (TUNING.KEI_WAGBOSS_ORBITAL_STRIKE_COOLDOWN or 20)
    DisableTargetFx(slots)
    slots._kei_wagboss_target_ready_task = inst:DoTaskInTime(
        TUNING.KEI_WAGBOSS_ORBITAL_STRIKE_COOLDOWN or 20,
        function()
            slots._kei_wagboss_target_ready_task = nil
            RefreshTargetFx(slots, inst)
        end
    )
    KeiEffectManager.RegisterTask(inst, slots._kei_wagboss_target_ready_task, "wagboss_target_ready", function()
        slots._kei_wagboss_target_ready_task = nil
    end)
end

return WagbossEffect
