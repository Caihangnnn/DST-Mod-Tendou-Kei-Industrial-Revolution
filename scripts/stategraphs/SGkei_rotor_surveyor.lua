local DroneAnimation = require("kei/drone/animation")

local function GetDroneSide(inst)
    local side = DroneAnimation.GetSide(inst, inst.sg.mem.drone_side)
    inst.sg.mem.drone_side = side
    return side
end

local function PlayDroneAnimation(inst, prefix, loop, paired, force)
    return DroneAnimation.Play(inst, prefix, loop, GetDroneSide(inst), paired, force)
end

local function ForceVisible(inst)
    inst:Show()
end

local function UpdateHoverMotion(inst, dt)
    if inst:IsAsleep() then
        return
    end

    local period = 1.2
    local amp = 0.2
    local ht0 = 7
    local liftoff_period = period * 3

    local x, y, z = inst.Transform:GetWorldPosition()
    local t = inst.sg.statemem.t
    if t == nil then
        if y < 2 then
            amp = ht0
            period = liftoff_period
            if y <= 0 then
                y = 0.01
                inst.Physics:Teleport(x, y, z)
            end
            t = math.asin((y - ht0) / amp) * period / TWOPI
        elseif y < ht0 - amp - 0.5 then
            t = 0.75 * period
        else
            t = math.random() * period
        end
        t = t + dt
    else
        t = t + dt
        if t < 0 then
            amp = ht0
            period = liftoff_period
        end
    end

    local ht = ht0 + math.sin(t * TWOPI / period) * amp
    local vy = (ht - y) * 15
    local vx, _, vz = inst.Physics:GetMotorVel()
    inst.Physics:SetMotorVel(vx, vy, vz)
    inst.sg.statemem.t = t
end

local function UpdateHover(inst, dt)
    UpdateHoverMotion(inst, dt)
    ForceVisible(inst)
    PlayDroneAnimation(inst, "fly_loop", true)
end

local function UpdateProjection(inst, dt)
    if inst:IsAsleep() then
        return
    end
    -- Projection changes the visual layer only; it keeps the same airborne
    -- hover/motion rules as the normal flight state.
    UpdateHoverMotion(inst, dt)
    ForceVisible(inst)
    PlayDroneAnimation(inst, "guang_loop", true)
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
    PlayDroneAnimation(inst, "fly_loop", true)
end

local function UpdateGround(inst)
    ForceVisible(inst)
    PlayDroneAnimation(inst, "idle_ground", true)
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
            PlayDroneAnimation(inst, "idle_ground", true, false, true)
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

        timeline =
        {
            FrameEvent(0, function(inst)
                inst.SoundEmitter:PlaySoundWithParams(
                    "rifts5/wagdrone_rolling/beep_turnon",
                    { pitch = 0.9 },
                    0.4
                )
            end),
        },

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
            PlayDroneAnimation(inst, "fly_loop", true, false, true)
        end,

        onupdate = UpdateHover,
    },

    State{
        name = "projection",
        tags = { "busy", "airborne", "projection" },

        onenter = function(inst)
            ForceVisible(inst)
            PlayDroneAnimation(inst, "guang_pre", false, false, true)
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
            PlayDroneAnimation(inst, "guang_loop", true, false, true)
        end,

        onupdate = UpdateProjection,
    },

    State{
        name = "projection_pst",
        tags = { "busy", "airborne", "projection" },

        onenter = function(inst)
            ForceVisible(inst)
            PlayDroneAnimation(inst, "guang_pst", false, false, true)
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
            PlayDroneAnimation(inst, "fly_loop", true, false, true)
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
