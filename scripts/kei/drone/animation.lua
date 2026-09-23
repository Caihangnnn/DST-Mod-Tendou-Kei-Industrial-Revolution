-- Kei 无人机的双面动画辅助。
--
-- kei_drone 的 upside/downside 是同一动作的两个视图，不是四向动画。
-- 无人机的 Transform 旋转沿用电刑机的约定：实体自身的前方为
-- (cos(rotation), -sin(rotation))，因此用前进方向的 z 分量决定显示哪一面。

local DroneAnimation = {}

local SIDE_EPSILON = 0.01
local DIAGONAL_FACING_OFFSET = 45

function DroneAnimation.GetFacingRotation(rotation)
    rotation = (rotation or 0) % 360
    return (
        DIAGONAL_FACING_OFFSET
        + math.floor((rotation - DIAGONAL_FACING_OFFSET) / 90 + 0.5) * 90
    ) % 360
end

function DroneAnimation.SetFacingRotation(inst, rotation)
    rotation = DroneAnimation.GetFacingRotation(rotation)
    if inst ~= nil and inst.Transform ~= nil then
        inst.Transform:SetRotation(rotation)
    end
    return rotation
end

function DroneAnimation.GetSideFromDirection(dx, dz, previous)
    if dz > SIDE_EPSILON then
        return "upside"
    elseif dz < -SIDE_EPSILON then
        return "downside"
    end
    return previous or "upside"
end

function DroneAnimation.GetSideFromRotation(rotation, previous)
    rotation = rotation or 0
    -- SetMotorVel(speed, 0, 0) 在旋转后的实体局部空间中沿前方移动。
    return DroneAnimation.GetSideFromDirection(
        math.cos(rotation * DEGREES),
        -math.sin(rotation * DEGREES),
        previous
    )
end

function DroneAnimation.GetSide(inst, previous)
    if inst == nil or inst.Transform == nil then
        return previous or "upside"
    end
    return DroneAnimation.GetSideFromRotation(inst.Transform:GetRotation(), previous)
end

-- 仅在动画面发生变化时重播，并尽量保留切换前的播放进度。
-- 这对 loop 动画尤其重要，否则无人机每次转向都会跳回第一帧。
function DroneAnimation.Play(inst, prefix, loop, side, paired, force)
    if inst == nil or inst.AnimState == nil then
        return side or "upside"
    end

    side = side or "upside"
    local animation = paired == true and prefix .. "_" .. side .. "_1" or prefix
    -- Do not query GetCurrentAnimationName here. On the DST runtime this
    -- native accessor can return the internal sentinel "FROMNUM" for a
    -- hashed animation, which is not a real animation name. Keeping the
    -- name we requested also makes the transition deterministic across the
    -- server and client stategraphs.
    local current = inst._kei_drone_animation_name
    if force == true or current ~= animation then
        local progress = 0
        local length = inst.AnimState:GetCurrentAnimationLength()
        -- 只在同一组动画换 upside/downside 时保留进度。不能把
        -- fly_pre 的结束进度带到 fly_loop，否则会从循环末帧开始，
        -- 在某些 KAnim 时序下表现为前摇结束后无人机消失。
        local preserve_progress = current ~= nil
            and string.find(current, "^" .. prefix .. "_") ~= nil
        if preserve_progress and length ~= nil and length > 0 then
            progress = (inst.AnimState:GetCurrentAnimationTime() or 0) / length
        end

        inst.AnimState:PlayAnimation(animation, loop == true)
        inst._kei_drone_animation_name = animation

        local new_length = inst.AnimState:GetCurrentAnimationLength()
        if loop == true
            and inst.AnimState.SetTime ~= nil
            and new_length ~= nil
            and new_length > 0
            and progress > 0
        then
            inst.AnimState:SetTime(math.min(progress, 1) * new_length)
        end
    end

    return side
end

function DroneAnimation.Push(inst, prefix, loop, side, paired)
    if inst == nil or inst.AnimState == nil or inst.AnimState.PushAnimation == nil then
        return side or "upside"
    end

    side = side or "upside"
    inst.AnimState:PushAnimation(
        paired == true and prefix .. "_" .. side .. "_1" or prefix,
        loop == true
    )
    return side
end

return DroneAnimation
