-- 发条主教协议（bishop）：协议存在期间始终获得羊角冻同款电击攻击。

local BishopEffect = {}
local KeiEffectManager = require("kei/effect_manager")

local ELECTRIC_BUFF_NAME = "kei_bishop_electricattack"

local function EnsureElectricAttacks(inst)
    if inst.components.electricattacks == nil then
        inst:AddComponent("electricattacks")
    end
    return inst.components.electricattacks
end

local function ShouldSkipAttackFx(attacker, data)
    local weapon = data ~= nil and data.weapon or nil
    if weapon == nil then
        return false
    end

    if data.projectile == nil then
        if weapon.components.projectile ~= nil then
            return true
        end
        if weapon.components.complexprojectile ~= nil then
            return true
        end
        if weapon.components.weapon ~= nil and weapon.components.weapon:CanRangedAttack() then
            return true
        end
    end

    return weapon.components.weapon ~= nil and weapon.components.weapon.stimuli == "electric"
end

local function SpawnAttackSpark(attacker, data)
    if data == nil or data.target == nil or ShouldSkipAttackFx(attacker, data) then
        return
    end

    if SpawnElectricHitSparks ~= nil then
        local source = data.projectile ~= nil and data.projectile:IsValid() and data.projectile or attacker
        SpawnElectricHitSparks(source, data.target, true)
    end
end

local function AddElectricSource(slots, inst)
    local electricattacks = EnsureElectricAttacks(inst)
    if electricattacks ~= nil then
        electricattacks:AddSource(slots)
    end
end

local function RemoveElectricSource(slots, inst)
    if inst.components.electricattacks ~= nil then
        inst.components.electricattacks:RemoveSource(slots)
    end
end

-- 启用常驻电击攻击；不再依赖会过期的 food buff。
function BishopEffect.Enable(slots, inst)
    if slots == nil or inst == nil then
        return
    end

    if inst.RemoveDebuff ~= nil then
        inst:RemoveDebuff(ELECTRIC_BUFF_NAME)
    end

    AddElectricSource(slots, inst)

    if slots._kei_bishop_onattackother == nil then
        slots._kei_bishop_onattackother = function(attacker, data)
            SpawnAttackSpark(attacker, data)
        end
        inst:ListenForEvent("onattackother", slots._kei_bishop_onattackother)
    end

    if slots._kei_bishop_charge_fx_task == nil then
        local function SpawnChargeFx()
            local fx = SpawnPrefab("electricchargedfx")
            if fx ~= nil and fx.SetTarget ~= nil then
                fx:SetTarget(inst)
                KeiEffectManager.Register(inst, fx)
            end
        end
        SpawnChargeFx()
        slots._kei_bishop_charge_fx_task = inst:DoPeriodicTask(8, SpawnChargeFx)
        KeiEffectManager.RegisterTask(inst, slots._kei_bishop_charge_fx_task, "bishop_charge_fx", function()
            slots._kei_bishop_charge_fx_task = nil
        end)
    end
end

-- 移除协议时清理本协议添加的电击 source 和命中特效监听。
function BishopEffect.Disable(slots, inst)
    if slots == nil or inst == nil then
        return
    end

    RemoveElectricSource(slots, inst)

    if slots._kei_bishop_onattackother ~= nil then
        inst:RemoveEventCallback("onattackother", slots._kei_bishop_onattackother)
        slots._kei_bishop_onattackother = nil
    end

    if slots._kei_bishop_charge_fx_task ~= nil then
        slots._kei_bishop_charge_fx_task:Cancel()
        slots._kei_bishop_charge_fx_task = nil
    end
    KeiEffectManager.Release(inst, "bishop_charge_fx", "protocol_disable")

    if inst.RemoveDebuff ~= nil then
        inst:RemoveDebuff(ELECTRIC_BUFF_NAME)
    end
end

return BishopEffect
