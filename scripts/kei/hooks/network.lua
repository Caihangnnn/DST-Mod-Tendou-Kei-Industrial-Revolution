local KEI_RPC_NAMESPACE = "TendouKei"
local ClientSettings = require("kei/client_settings")
local KeiEffectManager = require("kei/effect_manager")

-- The engine can dispatch the disconnect callback after the world entity has
-- already been removed during shard migration. The vanilla handler assumes
-- TheWorld still exists, so safely ignore that late callback.
local old_on_player_leave = GLOBAL.OnPlayerLeave
if old_on_player_leave ~= nil then
    GLOBAL.OnPlayerLeave = function(player_guid, expected, ...)
        if GLOBAL.TheWorld == nil then
            return
        end
        return old_on_player_leave(player_guid, expected, ...)
    end
end

 

local function HasMutatedWargProtocol(player)
    return player ~= nil
        and player.components.kei_protocolslots ~= nil
        and player.components.kei_protocolslots:HasCombatProtocol("mutatedwarg")
end

AddModRPCHandler(KEI_RPC_NAMESPACE, "MiniAliceAction", function(player, action)
    if player == nil
        or player.components == nil
        or player.components.kei_protocolslots == nil
        or not player:HasTag("kei")
        or player:HasTag("playerghost")
        or player:HasTag("kei_dormant")
        or type(action) ~= "string"
    then
        return
    end

    player.components.kei_protocolslots:PerformMiniAliceAction(action)
end)

local function IsMutatedWargFlameReady(player)
    return player ~= nil
        and player:HasTag("kei")
        and not player:HasTag("playerghost")
        and not player:HasTag("kei_dormant")
        and (player.components.health == nil or not player.components.health:IsDead())
        and HasMutatedWargProtocol(player)
        and player.kei_mutatedwarg_flamethrower_cd_task == nil
        and player.components.inventory ~= nil
        and player.components.inventory:GetActiveItem() == nil
        and player.components.sanity ~= nil
        and player.components.sanity.current >= (TUNING.KEI_MUTATEDWARG_FLAMETHROWER_STABILITY_COST or 10)
end

local function SpawnMutatedWargFlameReadyFx(player)
    if player == nil
        or not player:IsValid()
        or not player:HasTag("kei")
        or player:HasTag("playerghost")
        or player:HasTag("kei_dormant")
        or (player.components.health ~= nil and player.components.health:IsDead())
        or not HasMutatedWargProtocol(player)
    then
        return
    end

    local ismount = player.components.rider ~= nil and player.components.rider:IsRiding()
    local fx = SpawnPrefab(ismount and "fx_book_moon_mount" or "fx_book_moon")
    if fx ~= nil then
        fx.persists = false
        KeiEffectManager.Register(player, fx)

        if ismount then
            fx.Transform:SetSixFaced()
        end
        fx.entity:SetParent(player.entity)
        fx.Transform:SetPosition(0, 0, 0)
        fx.Transform:SetRotation(0)
        fx:ListenForEvent("onremove", function()
            if fx:IsValid() then
                fx:Remove()
            end
        end, player)
    end
end

local function StartMutatedWargFlameCooldown(player)
    if player == nil then
        return
    end
    if player.kei_mutatedwarg_flamethrower_cd_task ~= nil then
        player.kei_mutatedwarg_flamethrower_cd_task:Cancel()
    end
    player.kei_mutatedwarg_flamethrower_cd_task = player:DoTaskInTime(TUNING.KEI_MUTATEDWARG_FLAMETHROWER_COOLDOWN or 10, function(inst)
        inst.kei_mutatedwarg_flamethrower_cd_task = nil
        SpawnMutatedWargFlameReadyFx(inst)
    end)
end

local function RefreshMutatedWargChannelcastAnimation(player)
    if player == nil
        or player.sg == nil
        or player.sg:HasStateTag("busy")
        or player.sg:HasStateTag("overridelocomote")
    then
        return
    end

    if player.sg:HasStateTag("moving")
        and player.components.locomotor ~= nil
        and player.components.locomotor:WantsToMoveForward()
    then
        player.sg:GoToState("run_start")
    else
        player.sg:GoToState("idle")
    end
end

AddModRPCHandler(KEI_RPC_NAMESPACE, "MutatedWargFlame", function(player, x, z)
    if player == nil or not player:HasTag("kei") then
        return
    end

    if not IsMutatedWargFlameReady(player) then
        return
    end

    local px, py, pz = player.Transform:GetWorldPosition()
    if x == nil or z == nil then
        return
    end
    local dx = x - px
    local dz = z - pz
    if dx * dx + dz * dz <= 0 then
        return
    end

    local fx = SpawnPrefab("kei_mutatedwarg_flamethrower")
    if fx == nil then
        return
    end

    player.components.sanity:DoDelta(-(TUNING.KEI_MUTATEDWARG_FLAMETHROWER_STABILITY_COST or 10))
    player:ForceFacePoint(x, py, z)
    StartMutatedWargFlameCooldown(player)

    fx.Transform:SetPosition(px, py, pz)
    fx:SetCaster(player, Vector3(x, py, z))
    KeiEffectManager.Register(player, fx, "mutatedwarg_flamethrower", function()
        if player.kei_mutatedwarg_flamethrower_fx == fx then
            player.kei_mutatedwarg_flamethrower_fx = nil
        end
        player.kei_mutatedwarg_channelcasting = nil
    end)
    player.kei_mutatedwarg_flamethrower_fx = fx
    player.kei_mutatedwarg_channelcasting = true
    fx:ListenForEvent("onremove", function()
        if player.kei_mutatedwarg_flamethrower_fx == fx then
            player.kei_mutatedwarg_flamethrower_fx = nil
        end
        player.kei_mutatedwarg_channelcasting = nil
        RefreshMutatedWargChannelcastAnimation(player)
    end)

    if player.sg ~= nil then
        player.sg:GoToState("kei_mutatedwarg_flamethrower")
    end
end)

AddModRPCHandler(KEI_RPC_NAMESPACE, "MapTeleport", function(player, x, z)
    local teleport_power_cost = TUNING.KEI_MAP_TELEPORT_POWER_COST or 30
    local hunger = player ~= nil and player.components.hunger or nil
    if player ~= nil and (hunger == nil or hunger.current < teleport_power_cost) then
        if player.components.talker ~= nil then
            player.components.talker:Say(STRINGS.CHARACTERS.KEI.ANNOUNCE_KEI_MAP_TELEPORT_NO_POWER)
        end
        return
    end

    if player == nil
        or x == nil
        or z == nil
        or not player:HasTag("kei")
        or player:HasTag("playerghost")
        or player:HasTag("kei_dormant")
        or player:HasTag("noteleport")
        or player.sg == nil
        or player.components.kei_protocolslots == nil
        or not player.components.kei_protocolslots:HasLifeProtocol("map_teleport")
        or (player.components.health ~= nil and player.components.health:IsDead())
        or (player.components.rider ~= nil and player.components.rider:IsRiding())
        or (player.components.inventory ~= nil and player.components.inventory:IsHeavyLifting())
    then
        return
    end

    player.sg:GoToState("kei_map_teleport", Vector3(x, 0, z))
end)

AddModRPCHandler(KEI_RPC_NAMESPACE, "UpdateMutatedWargFlameAim", function(player, x, z)
    if player == nil
        or x == nil
        or z == nil
        or not player:HasTag("kei")
        or player:HasTag("playerghost")
        or player:HasTag("kei_dormant")
    then
        return
    end

    local fx = player.kei_mutatedwarg_flamethrower_fx
    if fx ~= nil and fx:IsValid() and fx.SetTargetPoint ~= nil then
        local _, y = player.Transform:GetWorldPosition()
        fx:SetTargetPoint(Vector3(x, y, z))
        player:ForceFacePoint(x, y, z)
    end
end)

-- Kei 的三项核心资源：电量、稳定性、机体完整度。

if not TheNet:IsDedicated() then
    AddClassPostConstruct("screens/mapscreen", function(self)
        local old_OnMouseButton = self.OnMouseButton
        self.OnMouseButton = function(self, button, down, ...)
            local player = ThePlayer
            if down
                and button == MOUSEBUTTON_RIGHT
                and player ~= nil
                and player:HasTag("kei")
                and not player:HasTag("playerghost")
                   and not player:HasTag("kei_dormant")
                   and player._kei_map_teleport_protocol_active ~= nil
                   and player._kei_map_teleport_protocol_active:value()
                   and player.replica.hunger ~= nil
                   and player.replica.hunger:GetCurrent() >= (TUNING.KEI_MAP_TELEPORT_POWER_COST or 30)
                   and player.replica.inventory ~= nil
                and player.replica.inventory:GetActiveItem() == nil
                and (player.replica.rider == nil or not player.replica.rider:IsRiding())
                and (player.replica.inventory == nil or not player.replica.inventory:IsHeavyLifting())
                and self.minimap ~= nil
                and self.WidgetPosToMapPos ~= nil
                and self.ScreenPosToWidgetPos ~= nil
            then
                local screenpos = TheInput:GetScreenPosition()
                local mousemappos = self:WidgetPosToMapPos(self:ScreenPosToWidgetPos(screenpos))
                local x, z = self.minimap:MapPosToWorldPos(mousemappos:Get())
                SendModRPCToServer(MOD_RPC[KEI_RPC_NAMESPACE].MapTeleport, x, z)
                TheFrontEnd:PopScreen(self)
                return true
            end

            return old_OnMouseButton ~= nil and old_OnMouseButton(self, button, down, ...) or false
        end
    end)
end

if not TheNet:IsDedicated() and TheInput ~= nil then
    local kei_mutatedwarg_key_down = false
    local kei_mutatedwarg_aim_update_task = nil
    local kei_mutatedwarg_aim_update_stop_task = nil
    local kei_mutatedwarg_channelcast_stop_task = nil

    local function SetLocalMutatedWargChannelcasting(player, enabled)
        if player == nil then
            return
        end
        player.kei_mutatedwarg_channelcasting = enabled == true or nil
        RefreshMutatedWargChannelcastAnimation(player)
    end

    local function StopMutatedWargAimUpdates()
        if kei_mutatedwarg_aim_update_task ~= nil then
            kei_mutatedwarg_aim_update_task:Cancel()
            kei_mutatedwarg_aim_update_task = nil
        end
        if kei_mutatedwarg_aim_update_stop_task ~= nil then
            kei_mutatedwarg_aim_update_stop_task:Cancel()
            kei_mutatedwarg_aim_update_stop_task = nil
        end
        if kei_mutatedwarg_channelcast_stop_task ~= nil then
            kei_mutatedwarg_channelcast_stop_task:Cancel()
            kei_mutatedwarg_channelcast_stop_task = nil
        end
        SetLocalMutatedWargChannelcasting(ThePlayer, false)
    end

    local function SendMutatedWargAimUpdate()
        local player = ThePlayer
        if player == nil
            or player:HasTag("playerghost")
            or player:HasTag("kei_dormant")
            or player._kei_mutatedwarg_protocol_active == nil
            or not player._kei_mutatedwarg_protocol_active:value()
        then
            StopMutatedWargAimUpdates()
            return
        end

        local pos = TheInput:GetWorldPosition()
        if pos ~= nil then
            SendModRPCToServer(MOD_RPC[KEI_RPC_NAMESPACE].UpdateMutatedWargFlameAim, pos.x, pos.z)
        end
    end

    local function StartMutatedWargAimUpdates(player)
        StopMutatedWargAimUpdates()
        SetLocalMutatedWargChannelcasting(player, true)
        SendMutatedWargAimUpdate()
        kei_mutatedwarg_aim_update_task = player:DoPeriodicTask(
            TUNING.KEI_MUTATEDWARG_FLAMETHROWER_AIM_UPDATE_PERIOD or 0.1,
            SendMutatedWargAimUpdate
        )
        kei_mutatedwarg_aim_update_stop_task = player:DoTaskInTime(
            (TUNING.KEI_MUTATEDWARG_FLAMETHROWER_DURATION or 5) + 0.25,
            StopMutatedWargAimUpdates
        )
        kei_mutatedwarg_channelcast_stop_task = player:DoTaskInTime(
            TUNING.KEI_MUTATEDWARG_FLAMETHROWER_DURATION or 5,
            function()
                SetLocalMutatedWargChannelcasting(player, false)
                kei_mutatedwarg_channelcast_stop_task = nil
            end
        )
    end

    local function OnMutatedWargKeyDown()
        if kei_mutatedwarg_key_down then
            return
        end
        kei_mutatedwarg_key_down = true
        local player = ThePlayer
        local screen = TheFrontEnd ~= nil and TheFrontEnd:GetActiveScreen() or nil
        if player ~= nil
            and screen ~= nil
            and screen.name == "HUD"
            and player:HasTag("kei")
            and player._kei_mutatedwarg_protocol_active ~= nil
            and player._kei_mutatedwarg_protocol_active:value()
            and not player:HasTag("playerghost")
            and not player:HasTag("kei_dormant")
            and player.replica.inventory ~= nil
            and player.replica.inventory:GetActiveItem() == nil
        then
            local pos = TheInput:GetWorldPosition()
            if pos ~= nil then
                SendModRPCToServer(MOD_RPC[KEI_RPC_NAMESPACE].MutatedWargFlame, pos.x, pos.z)
                StartMutatedWargAimUpdates(player)
            end
        end
    end
    local function OnMutatedWargKeyUp()
        kei_mutatedwarg_key_down = false
    end

    ClientSettings:RegisterActionHandler("flame", OnMutatedWargKeyDown, OnMutatedWargKeyUp)
    ClientSettings:RegisterActionHandler("task_book", function()
        local player = ThePlayer
        local screen = TheFrontEnd ~= nil and TheFrontEnd:GetActiveScreen() or nil
        if player ~= nil and player:HasTag("kei") and player.HUD ~= nil then
            local taskbook_screen = player.HUD.kei_taskbookscreen
            if taskbook_screen ~= nil and taskbook_screen.inst:IsValid() then
                player.HUD:CloseKeiTaskBookScreen()
            elseif screen ~= nil and screen.name == "HUD" and POPUPS.KEI_TASK_BOOK ~= nil then
                POPUPS.KEI_TASK_BOOK.fn(player, true)
            end
        end
    end)
end

-- 注册可选角色。
