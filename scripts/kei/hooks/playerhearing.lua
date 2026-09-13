-- playerhearing is an active client-side player component.  On reconnects,
-- seamless swaps, and with equipment-slot mods enabled, vanilla can create it
-- one tick before the player's inventory replica exists.  Its constructor
-- schedules an immediate EquipHasTag() call and does not nil-check the
-- replica, which causes playerhearing.lua:27 to abort the client.
--
-- Do not create a fake inventory replica here.  Other systems need the real
-- inventory_replica, and a fake object would hide the synchronization race.
-- Instead, defer only playerhearing until the real replica is available.

local function HasInventoryReplica(player)
    return player ~= nil
        and player.replica ~= nil
        and player.replica.inventory ~= nil
end

local function CancelPlayerHearingRetry(player)
    if player ~= nil and player._kei_playerhearing_retry_task ~= nil then
        player._kei_playerhearing_retry_task:Cancel()
        player._kei_playerhearing_retry_task = nil
    end
end

local function EnsurePlayerHearing(player)
    if player == nil
        or not player:IsValid()
        or TheWorld == nil
        or TheWorld.ismastersim
        or player.prefab ~= "kei"
    then
        return
    end

    if player.components ~= nil and player.components.playerhearing ~= nil then
        CancelPlayerHearingRetry(player)
        return
    end

    if not HasInventoryReplica(player) then
        if player._kei_playerhearing_retry_task == nil then
            player._kei_playerhearing_retry_task = player:DoPeriodicTask(.1, function(inst)
                if inst == nil or not inst:IsValid() then
                    CancelPlayerHearingRetry(inst)
                    return
                end

                if HasInventoryReplica(inst) then
                    EnsurePlayerHearing(inst)
                end
            end)
        end
        return
    end

    CancelPlayerHearingRetry(player)
    if player.components == nil or player.components.playerhearing == nil then
        local addcomponent = player._kei_playerhearing_original_addcomponent
        if addcomponent ~= nil then
            addcomponent(player, "playerhearing")
        end
    end
end

local function InstallPlayerHearingGuard(player)
    if player == nil
        or player.prefab ~= "kei"
        or TheWorld == nil
        or TheWorld.ismastersim
        or player._kei_playerhearing_guard_installed
    then
        return
    end

    local original_addcomponent = player.AddComponent
    if type(original_addcomponent) ~= "function" then
        return
    end

    player._kei_playerhearing_guard_installed = true
    player._kei_playerhearing_original_addcomponent = original_addcomponent

    -- Vanilla calls AddActivePlayerComponents from the setowner path.  The
    -- instance method wrapper lets that call remain unchanged while deferring
    -- only playerhearing when inventory_replica has not arrived yet.
    player.AddComponent = function(inst, name, ...)
        if name == "playerhearing" and not HasInventoryReplica(inst) then
            EnsurePlayerHearing(inst)
            return nil
        end
        return original_addcomponent(inst, name, ...)
    end

    -- The replica may arrive after setowner, after playeractivated, or during
    -- a reconnect.  These events make the retry prompt instead of waiting for
    -- the next periodic tick, while the retry task still covers all paths.
    player:ListenForEvent("setowner", EnsurePlayerHearing)
    player:ListenForEvent("playeractivated", EnsurePlayerHearing)
    player:ListenForEvent("inventorychanged", EnsurePlayerHearing)

    EnsurePlayerHearing(player)
end

-- Bind directly to Kei's prefab.  AddPlayerPostInit is implemented through
-- a generic player-tag callback; during reconnects the tag callback can run
-- after player_common's setowner path has already started adding active
-- components.  A prefab post-init runs as soon as this specific entity is
-- created, before ownership activation, so the guard can catch the first
-- playerhearing AddComponent call reliably.
AddPrefabPostInit("kei", InstallPlayerHearingGuard)
