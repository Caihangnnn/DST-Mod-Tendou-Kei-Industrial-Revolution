-- 拾荒疯猪协议公共实现：控制免疫、盾牌特效、伤害吸收。

local BeastCommon = require("kei/protocols/combat/effects/beast/_beast_common")
local KeiEffectManager = require("kei/effect_manager")
local DAYWALKER2_SHIELD_FOLLOW_PERIOD = FRAMES

local Daywalker2Common = {}

local function HasSharedImmunitySource(slots)
    return BeastCommon.HasAnySource(slots._kei_shared_immunity_sources)
end

local function PositionShieldFx(slots)
    local fx = slots._kei_daywalker2_shield_fx
    if fx ~= nil and fx:IsValid() then
        local x, y, z = slots.inst.Transform:GetWorldPosition()
        fx.Transform:SetPosition(x, y + 1.5, z)
        fx.Transform:SetRotation(0)
    end
end

local function EnableShieldFx(slots, inst)
    if slots._kei_daywalker2_shield_fx ~= nil and slots._kei_daywalker2_shield_fx:IsValid() then
        return
    end

    local fx = SpawnPrefab("kei_daywalker2_shield_fx")
    if fx ~= nil then
        slots._kei_daywalker2_shield_fx = fx
        KeiEffectManager.Register(inst, fx, "daywalker2_shield", function()
            slots._kei_daywalker2_shield_fx = nil
            slots._kei_daywalker2_shield_follow_task = nil
        end)
        PositionShieldFx(slots)
        slots._kei_daywalker2_shield_follow_task = inst:DoPeriodicTask(DAYWALKER2_SHIELD_FOLLOW_PERIOD, function()
            PositionShieldFx(slots)
        end)
        KeiEffectManager.SetTask(inst, "daywalker2_shield", slots._kei_daywalker2_shield_follow_task)
    end
end

local function DisableShieldFx(slots)
    if slots._kei_daywalker2_shield_follow_task ~= nil then
        slots._kei_daywalker2_shield_follow_task:Cancel()
        slots._kei_daywalker2_shield_follow_task = nil
    end
    if not KeiEffectManager.Remove(slots.inst, "daywalker2_shield", "protocol_disable") then
        if slots._kei_daywalker2_shield_fx ~= nil and slots._kei_daywalker2_shield_fx:IsValid() then
            slots._kei_daywalker2_shield_fx:Remove()
        end
    end
    slots._kei_daywalker2_shield_fx = nil
end

-- 判断高级协议是否激活，用于压制初级协议的同类能力。
function Daywalker2Common.HasAdvanced(slots)
    return BeastCommon.HasProtocol(slots, "daywalker2")
end

-- 霸体标签可能同时由拾荒疯猪和发条战车提供，按来源维护，避免互相误删。
function Daywalker2Common.EnableSharedImmunity(slots, inst, source)
    if slots == nil or inst == nil or source == nil then
        return
    end

    slots._kei_shared_immunity_sources = slots._kei_shared_immunity_sources or {}
    BeastCommon.AddSource(slots._kei_shared_immunity_sources, source)
    if not inst:HasTag("kei_stagger_immune") then
        inst:AddTag("kei_stagger_immune")
        slots._kei_stagger_added_tag = true
    end
    if not inst:HasTag("kei_control_immune") then
        inst:AddTag("kei_control_immune")
        slots._kei_control_added_tag = true
    end
end

function Daywalker2Common.DisableSharedImmunity(slots, inst, source)
    if slots == nil or inst == nil or source == nil then
        return
    end

    local sources = slots._kei_shared_immunity_sources
    if sources ~= nil and BeastCommon.RemoveSource(sources, source) then
        return
    end

    if slots._kei_stagger_added_tag then
        inst:RemoveTag("kei_stagger_immune")
    end
    if slots._kei_control_added_tag then
        inst:RemoveTag("kei_control_immune")
    end
    slots._kei_stagger_added_tag = nil
    slots._kei_control_added_tag = nil
    slots._kei_shared_immunity_sources = nil
end

function Daywalker2Common.EnableImmunity(slots, inst, source)
    source = source or "daywalker2"
    slots._kei_daywalker2_sources = slots._kei_daywalker2_sources or {}
    slots._kei_daywalker2_sources[source] = true

    -- 读档或其他效果清理可能只移除了标签，保留了来源记录；
    -- 每次启用都校准实际霸体状态和护盾。
    Daywalker2Common.EnableSharedImmunity(slots, inst, source)
    EnableShieldFx(slots, inst)
end

function Daywalker2Common.DisableImmunity(slots, inst, source)
    source = source or "daywalker2"
    local sources = slots._kei_daywalker2_sources
    if sources ~= nil then
        sources[source] = nil
    end

    if not BeastCommon.HasAnySource(sources) then
        DisableShieldFx(slots)
        slots._kei_daywalker2_sources = nil
    end

    Daywalker2Common.DisableSharedImmunity(slots, inst, source)
end

function Daywalker2Common.SetAbsorb(slots, inst, amount)
    slots:SetCombatDamageReduction("kei_daywalker2", amount)
end

function Daywalker2Common.ClearAbsorb(slots, inst)
    slots:SetCombatDamageReduction("kei_daywalker2", nil)
end

return Daywalker2Common
