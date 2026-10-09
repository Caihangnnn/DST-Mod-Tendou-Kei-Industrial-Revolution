-- 无人机动画统一使用不带方向后缀的动画名。

local DroneAnimation = {}

local FIXED_SIDE = "upside"

function DroneAnimation.GetFacingRotation(rotation)
    return ((rotation or 0) % 360 + 360) % 360
end

function DroneAnimation.SetFacingRotation(inst, rotation)
    rotation = DroneAnimation.GetFacingRotation(rotation)
    if inst ~= nil and inst.Transform ~= nil then
        inst.Transform:SetRotation(rotation)
    end
    return rotation
end

function DroneAnimation.GetSideFromDirection(dx, dz, previous)
    return FIXED_SIDE
end

function DroneAnimation.GetSideFromRotation(rotation, previous)
    return FIXED_SIDE
end

function DroneAnimation.GetSide(inst, previous)
    return FIXED_SIDE
end

function DroneAnimation.GetFixedSide()
    return FIXED_SIDE
end

function DroneAnimation.Play(inst, prefix, loop, side, paired, force, directional)
    if inst ~= nil and inst.AnimState ~= nil then
        inst.AnimState:PlayAnimation(prefix, loop == true)
    end
    return FIXED_SIDE
end

function DroneAnimation.Push(inst, prefix, loop, side, paired, directional)
    if inst == nil or inst.AnimState == nil or inst.AnimState.PushAnimation == nil then
        return FIXED_SIDE
    end

    inst.AnimState:PushAnimation(prefix, loop == true)
    return FIXED_SIDE
end

return DroneAnimation
