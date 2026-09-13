-- 独眼晶体巨鹿协议：攻击后生成时缓圈，使范围内非友方单位时间流速减半。

local SlowSources = require("kei/slow_sources")
local KeiEffectManager = require("kei/effect_manager")

local MUTATEDDEERCLOPS_AURA_SLOW_KEY = "kei_mutateddeerclops_aura"
local MUTATEDDEERCLOPS_AURA_FOLLOW_PERIOD = FRAMES
local MUTATEDDEERCLOPS_AURA_UPDATE_PERIOD = 0.25
local MUTATEDDEERCLOPS_AURA_MUST_TAGS = { "_combat", "_health" }
local MUTATEDDEERCLOPS_AURA_EXCLUDE_TAGS = { "INLIMBO", "FX", "NOCLICK", "DECOR", "playerghost" }

local MutatedDeerclopsEffect = {}

-- ---------- 辅助函数 ----------

local function IsValidTarget(owner, target)
    if target == nil
        or target == owner
        or not target:IsValid()
        or target:IsInLimbo()
        or target.components.health == nil
        or target.components.health:IsDead()
        or target.components.combat == nil
    then
        return false
    end
    local combat = owner.components.combat
    return combat == nil or not combat:IsAlly(target)
end

-- ---------- 减速管理 ----------

local function ApplySlow(slots, inst, target)
    if slots._kei_mutateddeerclops_slowed[target] ~= nil then
        return
    end

    local slow = TUNING.KEI_MUTATEDDEERCLOPS_AURA_SLOW_MULT or 0.5
    if not SlowSources.TryApply(target, MUTATEDDEERCLOPS_AURA_SLOW_KEY, inst, slow, slow) then
        return
    end

    local data = {}
    data.onremove = function()
        slots._kei_mutateddeerclops_slowed[target] = nil
    end
    inst:ListenForEvent("onremove", data.onremove, target)
    slots._kei_mutateddeerclops_slowed[target] = data

end

local function ClearSlow(slots, inst, target)
    local data = slots._kei_mutateddeerclops_slowed[target]
    if data == nil then
        return
    end

    slots._kei_mutateddeerclops_slowed[target] = nil
    inst:RemoveEventCallback("onremove", data.onremove, target)

    if target:IsValid() then
        SlowSources.Release(target, MUTATEDDEERCLOPS_AURA_SLOW_KEY, inst)
    end
end

local function ClearAllSlows(slots, inst)
    local targets = {}
    for target in pairs(slots._kei_mutateddeerclops_slowed or {}) do
        table.insert(targets, target)
    end
    for _, target in ipairs(targets) do
        ClearSlow(slots, inst, target)
    end
end

-- ---------- 接口方法 ----------

function MutatedDeerclopsEffect.Enable(slots, inst)
end

-- 处理攻击命中事件，根据协议等级触发附加战斗效果。
function MutatedDeerclopsEffect.OnHitOther(slots, inst, data)
    local now = GetTime()
    if (slots._kei_mutateddeerclops_aura_ready_time or 0) > now then
        return
    end
    slots._kei_mutateddeerclops_aura_ready_time = now + (TUNING.KEI_MUTATEDDEERCLOPS_AURA_COOLDOWN or 3)

    local fx = slots._kei_mutateddeerclops_aura
    if fx ~= nil and fx:IsValid() then
        fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
        if slots._kei_mutateddeerclops_aura_remove_task ~= nil then
            slots._kei_mutateddeerclops_aura_remove_task:Cancel()
        end
        slots._kei_mutateddeerclops_aura_remove_task = inst:DoTaskInTime(
            TUNING.KEI_MUTATEDDEERCLOPS_AURA_DURATION or 5, function()
                MutatedDeerclopsEffect.Disable(slots, inst)
            end)
        local x, y, z = fx.Transform:GetWorldPosition()
        local radius = TUNING.KEI_MUTATEDDEERCLOPS_AURA_RADIUS or 5.5
        local in_range = {}
        for _, target in ipairs(TheSim:FindEntities(x, y, z, radius,
            MUTATEDDEERCLOPS_AURA_MUST_TAGS, MUTATEDDEERCLOPS_AURA_EXCLUDE_TAGS)) do
            if IsValidTarget(inst, target) then
                in_range[target] = true
                ApplySlow(slots, inst, target)
            end
        end
        for target in pairs(slots._kei_mutateddeerclops_slowed or {}) do
            if not in_range[target] then
                ClearSlow(slots, inst, target)
            end
        end
        return
    end

    MutatedDeerclopsEffect.Disable(slots, inst)
    fx = SpawnPrefab("kei_mutateddeerclops_aura_fx")
    if fx == nil then
        return
    end

    slots._kei_mutateddeerclops_aura = fx
    KeiEffectManager.Register(inst, fx, "mutateddeerclops_aura", function()
        slots._kei_mutateddeerclops_aura = nil
        slots._kei_mutateddeerclops_aura_follow_task = nil
    end)
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    if fx.GrowFX ~= nil then
        fx:GrowFX()
    end

    slots._kei_mutateddeerclops_aura_follow_task = inst:DoPeriodicTask(
        MUTATEDDEERCLOPS_AURA_FOLLOW_PERIOD, function()
            if fx:IsValid() then
                fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
            end
        end)
    KeiEffectManager.SetTask(inst, "mutateddeerclops_aura", slots._kei_mutateddeerclops_aura_follow_task)
    slots._kei_mutateddeerclops_aura_task = inst:DoPeriodicTask(
        MUTATEDDEERCLOPS_AURA_UPDATE_PERIOD, function()
            if not fx:IsValid() then
                MutatedDeerclopsEffect.Disable(slots, inst)
                return
            end
            local ax, ay, az = fx.Transform:GetWorldPosition()
            local radius = TUNING.KEI_MUTATEDDEERCLOPS_AURA_RADIUS or 5.5
            local in_range = {}
            for _, target in ipairs(TheSim:FindEntities(ax, ay, az, radius,
                MUTATEDDEERCLOPS_AURA_MUST_TAGS, MUTATEDDEERCLOPS_AURA_EXCLUDE_TAGS)) do
                if IsValidTarget(inst, target) then
                    in_range[target] = true
                    ApplySlow(slots, inst, target)
                end
            end
            for target in pairs(slots._kei_mutateddeerclops_slowed or {}) do
                if not in_range[target] then
                    ClearSlow(slots, inst, target)
                end
            end
        end, 0)
    KeiEffectManager.AddTask(inst, "mutateddeerclops_aura", slots._kei_mutateddeerclops_aura_task)
    slots._kei_mutateddeerclops_aura_remove_task = inst:DoTaskInTime(
        TUNING.KEI_MUTATEDDEERCLOPS_AURA_DURATION or 5, function()
            MutatedDeerclopsEffect.Disable(slots, inst)
        end)
    KeiEffectManager.AddTask(inst, "mutateddeerclops_aura", slots._kei_mutateddeerclops_aura_remove_task)
end

-- 关闭协议效果，并清理启用时注册的持续能力。
function MutatedDeerclopsEffect.Disable(slots, inst)
    if slots._kei_mutateddeerclops_aura_task ~= nil then
        slots._kei_mutateddeerclops_aura_task:Cancel()
        slots._kei_mutateddeerclops_aura_task = nil
    end
    if slots._kei_mutateddeerclops_aura_follow_task ~= nil then
        slots._kei_mutateddeerclops_aura_follow_task:Cancel()
        slots._kei_mutateddeerclops_aura_follow_task = nil
    end
    if slots._kei_mutateddeerclops_aura_remove_task ~= nil then
        slots._kei_mutateddeerclops_aura_remove_task:Cancel()
        slots._kei_mutateddeerclops_aura_remove_task = nil
    end
    if slots._kei_mutateddeerclops_aura ~= nil then
        if not KeiEffectManager.Remove(inst, "mutateddeerclops_aura", "protocol_disable")
            and slots._kei_mutateddeerclops_aura:IsValid()
        then
            slots._kei_mutateddeerclops_aura:KillFX()
        end
        slots._kei_mutateddeerclops_aura = nil
    end
    ClearAllSlows(slots, inst)
end

return MutatedDeerclopsEffect
