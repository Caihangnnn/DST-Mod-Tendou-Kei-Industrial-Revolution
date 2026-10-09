local DroneAnimation = require("kei/drone/animation")

local function GetDroneSide(inst)
    local side = DroneAnimation.GetSide(inst, inst.sg.mem.drone_side)
    inst.sg.mem.drone_side = side
    return side
end

local function PlayDroneAnimation(inst, prefix, loop, paired, force, directional)
    return DroneAnimation.Play(inst, prefix, loop, GetDroneSide(inst), paired, force, directional)
end

local function HasProjectionRequest(inst)
    return (inst.scanning ~= nil and inst.scanning:value())
        or (inst.skill_beam_name ~= nil and inst.skill_beam_name:value() ~= "")
end

local function ShouldEndProjection(inst, dt)
    if HasProjectionRequest(inst) then
        inst.sg.statemem.no_skill_beam_time = nil
        return false
    end

    inst.sg.statemem.no_skill_beam_time = (inst.sg.statemem.no_skill_beam_time or 0) + (dt or FRAMES)
    return inst.sg.statemem.no_skill_beam_time >= 0.2
end

local function ForceVisible(inst)
    inst:Show()
end

local function UpdateHoverMotion(inst, dt)
    if inst:IsAsleep() then
        return
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    local t = inst.sg.statemem.t
    local target_height = 7

    if t == nil and y < 2 then
        if y <= 0 then
            y = 0.01
            inst.Physics:Teleport(x, y, z)
        end
        t = math.asin((y - target_height) / target_height) * 3 * 1.2 / TWOPI
    end

    if t ~= nil and t < 0 then
        t = math.min(0, t + dt)
        target_height = target_height + math.sin(t * TWOPI / (3 * 1.2)) * target_height
        inst.sg.statemem.t = t
    end

    local vy = (target_height - y) * 15
    local vx, _, vz = inst.Physics:GetMotorVel()
    inst.Physics:SetMotorVel(vx, vy, vz)
end

local function UpdateHover(inst, dt)
    UpdateHoverMotion(inst, dt)
    ForceVisible(inst)
end

local function UpdateProjection(inst, dt)
    if inst:IsAsleep() then
        return
    end
    if ShouldEndProjection(inst, dt) then
        inst.sg:GoToState("projection_pst")
        return
    end
    UpdateHoverMotion(inst, dt)
    ForceVisible(inst)
end

local LANDING_HEIGHT = 1.5
local LANDING_SPEED = 6

local function UpdateLanding(inst)
    if inst:IsAsleep() then
        return
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    if y <= LANDING_HEIGHT then
        inst.Physics:Stop()
        inst.Physics:Teleport(x, 0.01, z)
        inst.sg:GoToState("land_pst")
        return
    end

    ForceVisible(inst)
    inst.Physics:SetMotorVel(0, -LANDING_SPEED, 0)
end

local function UpdateGround(inst)
    ForceVisible(inst)
end

local function UpdateProjectionStart(inst, dt)
    UpdateHoverMotion(inst, dt)
    ForceVisible(inst)
end

local function UpdateProjectionEnd(inst)
    ForceVisible(inst)
end

local function SetAnimationTimeout(inst)
    local length = inst.AnimState:GetCurrentAnimationLength()
    inst.sg:SetTimeout(math.max(FRAMES, (length or 0) + FRAMES))
end

local states =
{
    State{
        name = "dormant",
        tags = { "idle", "dormant" },

        onenter = function(inst)
            ForceVisible(inst)
            local x, _, z = inst.Transform:GetWorldPosition()
            inst.Physics:Stop()
            inst.Physics:Teleport(x, 0.01, z)
            PlayDroneAnimation(inst, "idle_ground", true, false, true, true)
        end,

        onupdate = UpdateGround,
    },

    State{
        name = "takeoff",
        tags = { "busy", "takeoff" },

        onenter = function(inst)
            ForceVisible(inst)
            PlayDroneAnimation(inst, "fly_pre", false, true, true)
            inst.Physics:Stop()
            inst.sg.mem.vel = Vector3(0, 0, 0)
            inst.sg.statemem.t = nil
            SetAnimationTimeout(inst)
        end,

        events =
        {
            EventHandler("animover", function(inst)
                if inst.AnimState:AnimDone() then
                    inst.sg:GoToState("flight")
                end
            end),
        },

        ontimeout = function(inst)
            if inst.sg.currentstate ~= nil
                and inst.sg.currentstate.name == "takeoff"
            then
                inst.sg:GoToState("flight")
            end
        end,
    },

    State{
        name = "flight",
        tags = { "idle", "airborne", "air_standby" },

        onenter = function(inst)
            ForceVisible(inst)
            inst.AnimState:SetBank("kei_drone")
            inst.AnimState:SetBuild("kei_drone")
            if HasProjectionRequest(inst) then
                inst.sg:GoToState("projection")
                return
            end
            PlayDroneAnimation(inst, "fly_loop", true, false, true, true)
        end,

        onupdate = UpdateHover,
    },

    State{
        name = "projection",
        tags = { "busy", "airborne", "projection" },

        onupdate = UpdateProjectionStart,

        onenter = function(inst)
            ForceVisible(inst)
            PlayDroneAnimation(inst, "guang_pre", false, false, true, true)
            SetAnimationTimeout(inst)
        end,

        events =
        {
            EventHandler("animover", function(inst)
                if inst.AnimState:AnimDone() then
                    inst.sg:GoToState("projection_loop")
                end
            end),
        },

        ontimeout = function(inst)
            if inst.sg.currentstate ~= nil
                and inst.sg.currentstate.name == "projection"
            then
                inst.sg:GoToState("projection_loop")
            end
        end,
    },

    State{
        name = "projection_loop",
        tags = { "idle", "airborne", "projection" },

        onenter = function(inst)
            ForceVisible(inst)
            PlayDroneAnimation(inst, "guang_loop", true, false, true, true)
        end,

        onupdate = UpdateProjection,
    },

    State{
        name = "projection_pst",
        tags = { "busy", "airborne", "projection" },

        onupdate = UpdateProjectionEnd,

        onenter = function(inst)
            ForceVisible(inst)
            PlayDroneAnimation(inst, "guang_pst", false, false, true, true)
            SetAnimationTimeout(inst)
        end,

        events =
        {
            EventHandler("animover", function(inst)
                if inst.AnimState:AnimDone() then
                    inst.sg:GoToState("flight")
                end
            end),
        },

        ontimeout = function(inst)
            if inst.sg.currentstate ~= nil
                and inst.sg.currentstate.name == "projection_pst"
            then
                inst.sg:GoToState("flight")
            end
        end,
    },

    State{
        name = "landing",
        tags = { "busy", "landing" },

        onenter = function(inst)
            ForceVisible(inst)
            PlayDroneAnimation(inst, "fly_loop", true, false, true, true)
            inst.Physics:SetMotorVel(0, -LANDING_SPEED, 0)
        end,

        onupdate = UpdateLanding,
    },

    State{
        name = "land_pst",
        tags = { "busy", "landing" },

        onenter = function(inst)
            ForceVisible(inst)
            inst.Physics:Stop()
            PlayDroneAnimation(inst, "fly_pst", false, true, true)
            SetAnimationTimeout(inst)
        end,

        events =
        {
            EventHandler("animover", function(inst)
                if inst.AnimState:AnimDone() then
                    inst.sg:GoToState("dormant")
                end
            end),
        },

        ontimeout = function(inst)
            if inst.sg.currentstate ~= nil
                and inst.sg.currentstate.name == "land_pst"
            then
                inst.sg:GoToState("dormant")
            end
        end,
    },
}

return StateGraph("kei_rotor_surveyor", states, {}, "dormant")
