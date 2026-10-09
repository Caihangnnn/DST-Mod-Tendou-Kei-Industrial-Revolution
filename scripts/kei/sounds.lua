-- Kei's voice bank uses full Japanese interaction lines for talking and EX
-- animation lines for combat. The original weapon sound is kept intact.
local SOUND_ROOT = "tendou_kei_vc/tendou_kei_vc/"

local HIT_SOUND_ROOT = "kei_hit_sound/kei_hit_sound/"
local CAROL_EVENT_NAMES = {
    "attacked_1", "attacked_2", "attacked_3", "christmas_carol", "death",
    "do_emote", "drown_in_water", "feel_sleepy", "ghost_1", "ghost_2",
    "ghost_3", "ghost_4", "ghost_5", "pose", "talk_1", "talk_2",
    "talk_3", "talk_4", "talk_5", "yawn",
}
local CAROL_TRACK_TITLES = {
    "希望の朝へ (向着黎明奔去)",
    "かがやきサマーデイズ",
    "キラメクMiLieへ",
    "Memories of Kindness / 優しさの記憶",
    "Target for love (EN Full ver)",
}
local CAROL_BANKS = {
    -- The base Kei mod deliberately keeps only the first five Carol songs.
    -- The optional music pack appends its tracks through MusicAPI below.
    { root = "kei_carol_a01/kei_carol_a01/", count = 5 },
}
local CAROL_SOUNDS = {}
for _, bank in ipairs(CAROL_BANKS) do
    for slot = 1, bank.count do
        table.insert(CAROL_SOUNDS, bank.root .. CAROL_EVENT_NAMES[slot])
    end
end

local function Sound(name, sound_root)
    return (sound_root or SOUND_ROOT) .. name
end

local function IsValidCarolTrack(index)
    return type(index) == "number"
        and index >= 1
        and index <= #CAROL_SOUNDS
        and CAROL_SOUNDS[index] ~= nil
end

local function ChooseCarolSound(inst)
    local selected = inst ~= nil and inst._kei_carol_selected_index or nil
    if IsValidCarolTrack(selected) then
        return CAROL_SOUNDS[selected]
    end
    return CAROL_SOUNDS[math.random(5)]
end

local CAROL_VOLUME = 0.5
local CAROL_CHANNEL = "kei_carol_music"
local CAROL_RULE_SEQUENCE = "sequence"
local CAROL_RULE_RANDOM = "random"
local CAROL_RULE_LOOP = "loop"

-- The task-book UI uses this small client-side API instead of reaching into
-- the sound hook's local state. The public mode is sent to the master so the
-- native SoundEmitter can replicate the music to nearby clients.
local MusicAPI = rawget(GLOBAL, "TENDOU_KEI_MUSIC") or {}
GLOBAL.TENDOU_KEI_MUSIC = MusicAPI
MusicAPI.current_index = MusicAPI.current_index or 1
MusicAPI.volume = MusicAPI.volume or CAROL_VOLUME
MusicAPI.mode = MusicAPI.mode or "local"
MusicAPI.playing = MusicAPI.playing or false
MusicAPI.rule = MusicAPI.rule or CAROL_RULE_SEQUENCE
MusicAPI._registered_track_packs = MusicAPI._registered_track_packs or {}

-- Optional music mods can register additional tracks whether they load before
-- or after this mod. The same ordered registration is performed on clients
-- and the master, keeping UI and public-play RPC indexes in sync.
function MusicAPI:RegisterTrackPack(pack_id, tracks)
    if type(pack_id) ~= "string" or pack_id == ""
        or type(tracks) ~= "table"
        or self._registered_track_packs[pack_id]
    then
        return false
    end

    local added = 0
    for _, track in ipairs(tracks) do
        if type(track) == "table"
            and type(track.title) == "string"
            and type(track.address) == "string"
            and track.address ~= ""
        then
            table.insert(CAROL_TRACK_TITLES, track.title)
            table.insert(CAROL_SOUNDS, track.address)
            added = added + 1
        end
    end

    if added > 0 then
        self._registered_track_packs[pack_id] = true
        return true
    end
    return false
end

local pending_track_packs = rawget(GLOBAL, "TENDOU_KEI_MUSIC_PENDING_PACKS") or {}
for _, pack in ipairs(pending_track_packs) do
    if type(pack) == "table" then
        MusicAPI:RegisterTrackPack(pack.id, pack.tracks)
    end
end
GLOBAL.TENDOU_KEI_MUSIC_PENDING_PACKS = nil

local function UpdateClientCarolState()
    if ThePlayer ~= nil then
        ThePlayer._kei_carol_selected_index = MusicAPI.current_index
        ThePlayer._kei_carol_mode = MusicAPI.mode
        ThePlayer._kei_carol_volume = MusicAPI.volume
        ThePlayer._kei_carol_rule = MusicAPI.rule
    end
end

function MusicAPI:GetTrackCount()
    return #CAROL_SOUNDS
end

function MusicAPI:GetTrackTitle(index)
    return CAROL_TRACK_TITLES[index] or "未命名歌曲"
end

function MusicAPI:GetTrackAddress(index)
    return CAROL_SOUNDS[index]
end

function MusicAPI:GetTrackTitles()
    local titles = {}
    for index, title in ipairs(CAROL_TRACK_TITLES) do
        titles[index] = title
    end
    return titles
end

function MusicAPI:GetCurrentIndex()
    return self.current_index
end

function MusicAPI:IsPlaying()
    return self.playing
end

function MusicAPI:GetVolume()
    return self.volume
end

function MusicAPI:GetMode()
    return self.mode
end

function MusicAPI:GetRule()
    return self.rule
end

local function IsCarolSoundAddress(address)
    return address == "dontstarve/characters/kei/carol"
        or address == "dontstarve/characters/wendy/carol"
end

local function KillCarolMusic(inst)
    if inst ~= nil and inst.SoundEmitter ~= nil then
        inst.SoundEmitter:KillSound(CAROL_CHANNEL)
    end
end

local function PlayCarolMusicOnEmitter(inst, index, volume)
    if inst == nil or inst.SoundEmitter == nil or not IsValidCarolTrack(index) then
        return false
    end
    KillCarolMusic(inst)
    inst.SoundEmitter:PlaySound(CAROL_SOUNDS[index], CAROL_CHANNEL, volume)
    return true
end

local function CancelCarolRuleTask(inst)
    if inst ~= nil and inst._kei_carol_rule_task ~= nil then
        inst._kei_carol_rule_task:Cancel()
        inst._kei_carol_rule_task = nil
    end
end

local function GetNextCarolTrack(index, rule)
    if rule == CAROL_RULE_LOOP then
        return index
    elseif rule == CAROL_RULE_RANDOM then
        if #CAROL_SOUNDS <= 1 then return index end
        local next_index = index
        while next_index == index do
            next_index = math.random(#CAROL_SOUNDS)
        end
        return next_index
    end
    if index >= #CAROL_SOUNDS then return nil end
    return index + 1
end

local function StartLocalCarolRuleTask()
    if ThePlayer == nil then return end
    CancelCarolRuleTask(ThePlayer)
    ThePlayer._kei_carol_rule_task = ThePlayer:DoPeriodicTask(.5, function(inst)
        if MusicAPI.mode ~= "local" or not MusicAPI.playing then
            CancelCarolRuleTask(inst)
            return
        end
        if inst.SoundEmitter == nil or inst.SoundEmitter:PlayingSound(CAROL_CHANNEL) then
            return
        end
        local next_index = GetNextCarolTrack(MusicAPI.current_index, MusicAPI.rule)
        if next_index == nil then
            MusicAPI.playing = false
            UpdateClientCarolState()
            CancelCarolRuleTask(inst)
            return
        end
        MusicAPI:Play(next_index)
    end)
end

local function StartServerCarolRuleTask(inst)
    if inst == nil then return end
    CancelCarolRuleTask(inst)
    inst._kei_carol_rule_task = inst:DoPeriodicTask(.5, function(player)
        if player._kei_carol_mode ~= "public" or not player._kei_carol_playing then
            CancelCarolRuleTask(player)
            return
        end
        if player.SoundEmitter == nil or player.SoundEmitter:PlayingSound(CAROL_CHANNEL) then
            return
        end
        local next_index = GetNextCarolTrack(
            player._kei_carol_selected_index,
            player._kei_carol_rule or CAROL_RULE_SEQUENCE
        )
        if next_index == nil then
            player._kei_carol_playing = false
            CancelCarolRuleTask(player)
            return
        end
        player._kei_carol_selected_index = next_index
        PlayCarolMusicOnEmitter(player, next_index, player._kei_carol_volume or CAROL_VOLUME)
    end)
end

local function SendCarolMusicRPC(index, volume, mode, command, rule)
    if MOD_RPC ~= nil
        and MOD_RPC.TendouKei ~= nil
        and MOD_RPC.TendouKei.SetKeiCarolMusic ~= nil
    then
        SendModRPCToServer(
            MOD_RPC.TendouKei.SetKeiCarolMusic,
            index,
            volume,
            mode,
            command,
            rule
        )
    end
end

function MusicAPI:Play(index)
    index = tonumber(index) or self.current_index
    if not IsValidCarolTrack(index) then
        return false
    end
    self.current_index = index
    self.playing = true
    UpdateClientCarolState()
    print("[Tendou-Kei] music ui play track " .. tostring(index)
        .. " mode " .. tostring(self.mode) .. " volume " .. tostring(self.volume))
    if self.mode == "public" then
        if ThePlayer ~= nil then
            KillCarolMusic(ThePlayer)
        end
        SendCarolMusicRPC(index, self.volume, self.mode, "play", self.rule)
    elseif ThePlayer ~= nil then
        PlayCarolMusicOnEmitter(ThePlayer, index, self.volume)
        StartLocalCarolRuleTask()
        -- Clear a previous public playback on the master when switching back
        -- to local mode.
        SendCarolMusicRPC(index, self.volume, self.mode, "stop", self.rule)
    end
    return true
end

function MusicAPI:Pause()
    self.playing = false
    if ThePlayer ~= nil then
        CancelCarolRuleTask(ThePlayer)
    end
    UpdateClientCarolState()
    if ThePlayer ~= nil then
        KillCarolMusic(ThePlayer)
    end
    SendCarolMusicRPC(self.current_index, self.volume, self.mode, "stop", self.rule)
end

function MusicAPI:SetMode(mode)
    mode = mode == "public" and "public" or "local"
    if self.mode == mode then
        return
    end
    self.mode = mode
    UpdateClientCarolState()
    if mode == "local" then
        SendCarolMusicRPC(self.current_index, self.volume, mode, "stop", self.rule)
        if self.playing then
            if ThePlayer ~= nil then
                PlayCarolMusicOnEmitter(ThePlayer, self.current_index, self.volume)
                StartLocalCarolRuleTask()
            end
        elseif ThePlayer ~= nil then
            KillCarolMusic(ThePlayer)
        end
    else
        if ThePlayer ~= nil then
            KillCarolMusic(ThePlayer)
        end
        SendCarolMusicRPC(
            self.current_index,
            self.volume,
            mode,
            self.playing and "play" or "stop",
            self.rule
        )
    end
end

function MusicAPI:SetRule(rule)
    if rule ~= CAROL_RULE_RANDOM and rule ~= CAROL_RULE_LOOP then
        rule = CAROL_RULE_SEQUENCE
    end
    self.rule = rule
    UpdateClientCarolState()
    SendCarolMusicRPC(self.current_index, self.volume, self.mode, "rule", self.rule)
end

function MusicAPI:CycleRule()
    if self.rule == CAROL_RULE_SEQUENCE then
        self:SetRule(CAROL_RULE_RANDOM)
    elseif self.rule == CAROL_RULE_RANDOM then
        self:SetRule(CAROL_RULE_LOOP)
    else
        self:SetRule(CAROL_RULE_SEQUENCE)
    end
end

function MusicAPI:SetVolume(volume)
    self.volume = math.clamp(tonumber(volume) or CAROL_VOLUME, 0, 1)
    UpdateClientCarolState()
    if self.mode == "public" then
        SendCarolMusicRPC(self.current_index, self.volume, self.mode, "volume", self.rule)
    elseif ThePlayer ~= nil and self.playing and ThePlayer.SoundEmitter ~= nil then
        ThePlayer.SoundEmitter:SetVolume(CAROL_CHANNEL, self.volume)
    end
end

function MusicAPI:Next()
    local next_index
    if self.rule == CAROL_RULE_RANDOM then
        next_index = GetNextCarolTrack(self.current_index, CAROL_RULE_RANDOM)
    else
        next_index = self.current_index + 1
        if next_index > #CAROL_SOUNDS then next_index = 1 end
    end
    return self:Play(next_index)
end

function MusicAPI:Previous()
    local previous_index
    if self.rule == CAROL_RULE_RANDOM then
        previous_index = GetNextCarolTrack(self.current_index, CAROL_RULE_RANDOM)
    else
        previous_index = self.current_index - 1
        if previous_index < 1 then previous_index = #CAROL_SOUNDS end
    end
    return self:Play(previous_index)
end

AddModRPCHandler("TendouKei", "SetKeiCarolMusic", function(player, index, volume, mode, command, rule)
    if player == nil or player.prefab ~= "kei"
        or not IsValidCarolTrack(tonumber(index))
        or type(volume) ~= "number"
        or (mode ~= "local" and mode ~= "public")
        or (command ~= "play" and command ~= "stop" and command ~= "volume" and command ~= "rule")
        or (command == "rule" and rule ~= CAROL_RULE_SEQUENCE
            and rule ~= CAROL_RULE_RANDOM and rule ~= CAROL_RULE_LOOP)
    then
        return
    end

    index = tonumber(index)
    volume = math.clamp(volume, 0, 1)
    player._kei_carol_selected_index = index
    player._kei_carol_mode = mode
    player._kei_carol_volume = volume
    player._kei_carol_rule = rule or player._kei_carol_rule or CAROL_RULE_SEQUENCE
    print("[Tendou-Kei] music rpc " .. tostring(command)
        .. " track " .. tostring(index) .. " mode " .. tostring(mode))
    if command == "play" and mode == "public" then
        player._kei_carol_playing = true
        PlayCarolMusicOnEmitter(player, index, volume)
        StartServerCarolRuleTask(player)
    elseif command == "volume" and mode == "public" then
        if player.SoundEmitter ~= nil then
            player.SoundEmitter:SetVolume(CAROL_CHANNEL, volume)
        end
    elseif command == "rule" then
        if mode == "public" and player._kei_carol_playing then
            StartServerCarolRuleTask(player)
        end
    else
        player._kei_carol_playing = false
        CancelCarolRuleTask(player)
        KillCarolMusic(player)
    end
end)

-- /carol is implemented by the vanilla emote state and calls SoundEmitter
-- directly. Wrap the native emitter on both server and client so the random
-- music choice is made at the moment each Carol action starts.
local function InstallCarolSoundHook(inst)
    if inst == nil or inst.SoundEmitter == nil or inst.__kei_carol_sound_hooked then
        return
    end

    if type(inst.SoundEmitter) == "userdata" then
        inst.__kei_sound_emitter_userdata = inst.SoundEmitter
        inst.SoundEmitter = { inst = inst, name = "SoundEmitter" }
        setmetatable(inst.SoundEmitter, {
            __index = function(emitter, method_name)
                if emitter.inst ~= nil and emitter.name ~= nil and _G[emitter.name] ~= nil
                    and _G[emitter.name][method_name] ~= nil then
                    local native_method = _G[emitter.name][method_name]
                    local forwarded = function(_, ...)
                        return native_method(emitter.inst.__kei_sound_emitter_userdata, ...)
                    end
                    rawset(emitter, method_name, forwarded)
                    return forwarded
                end
            end,
        })
    end

    if type(inst.SoundEmitter) ~= "table" then
        return
    end
    local emitter = inst.SoundEmitter
    local old_play_sound = emitter.PlaySound
    if type(old_play_sound) ~= "function" then
        return
    end
    emitter.PlaySound = function(self, address, ...)
        if IsCarolSoundAddress(address) then
            local carol_mode = inst._kei_carol_mode
            if (carol_mode == "local" and TheWorld ~= nil and TheWorld.ismastersim)
                or (carol_mode == "public" and (TheWorld == nil or not TheWorld.ismastersim))
            then
                return
            end
            address = ChooseCarolSound(inst)
            print("[Tendou-Kei] carol music " .. tostring(address))
            local channel = select(1, ...)
            return old_play_sound(self, address, channel or CAROL_CHANNEL, CAROL_VOLUME)
        end
        return old_play_sound(self, address, ...)
    end

    local old_play_sound_with_params = emitter.PlaySoundWithParams
    if type(old_play_sound_with_params) == "function" then
        emitter.PlaySoundWithParams = function(self, address, ...)
            if IsCarolSoundAddress(address) then
                local carol_mode = inst._kei_carol_mode
                if (carol_mode == "local" and TheWorld ~= nil and TheWorld.ismastersim)
                    or (carol_mode == "public" and (TheWorld == nil or not TheWorld.ismastersim))
                then
                    return
                end
                address = ChooseCarolSound(inst)
                print("[Tendou-Kei] carol music " .. tostring(address))
                local params = select(1, ...)
                local ispredicted = select(3, ...)
                return old_play_sound_with_params(self, address, params, CAROL_VOLUME, ispredicted)
            end
            return old_play_sound_with_params(self, address, ...)
        end
    end
    inst.__kei_carol_sound_hooked = true
end

local TALK_VOICE_CHANNEL = "kei_talk_voice"
local ATTACK_VOICE_CHANNEL = "kei_attack_voice"
local UPGRADE_VOICE_CHANNEL = "kei_upgrade_voice"
local HIT_VOICE_CHANNEL = "kei_hit_voice"
local DEATH_VOICE_CHANNEL = "kei_death_voice"
-- All Kei voice lines share one emitter channel so a new line always stops
-- the previous one, including a regular line interrupted by combat.
local VOICE_CHANNEL = "kei_voice"
local VOICE_PRIORITY_REGULAR = 1
local VOICE_PRIORITY_COMBAT = 2
local VOICE_PRIORITY_SPECIAL = 3
local COMBAT_VOICE_MIN_INTERVAL = 20
local COMBAT_VOICE_MAX_INTERVAL = 40
local COMBAT_VOICE_REGULAR_LOCK = 1.5
local REGULAR_VOICE_MIN_INTERVAL = 2 * 60
local REGULAR_VOICE_MAX_INTERVAL = 4 * 60
local ACTION_VOICE_MIN_INTERVAL = 30
local ACTION_VOICE_MAX_INTERVAL = 60
local REGULAR_TALK_VOICES = {
    "talk_1", "talk_2", "talk_3", "talk_4", "talk_5",
    "ghost_1", "ghost_2", "ghost_3", "ghost_5", "do_emote", "yawn",
}
local DEATH_VOICES = { "christmas_carol", "death" }
-- These are the two requested hit reactions. They live in a separate bank so
-- the three short attack shouts keep their existing main-bank slots.
local HIT_VOICES = { "attacked_1", "attacked_2" }
-- The extracted bank has four complete upgrade lines. Cycle them if the
-- server configuration allows more than four slot unlocks.
local UPGRADE_VOICES = { "drown_in_water", "feel_sleepy", "pose", "ghost_4" }

-- These are the three requested short battle lines.
local ATTACK_VOICES = { "attacked_1", "attacked_2", "attacked_3" }

local VOICE_DEFINITIONS = {
    { name = "talk_1", channel = TALK_VOICE_CHANNEL },
    { name = "talk_2", channel = TALK_VOICE_CHANNEL },
    { name = "talk_3", channel = TALK_VOICE_CHANNEL },
    { name = "talk_4", channel = TALK_VOICE_CHANNEL },
    { name = "talk_5", channel = TALK_VOICE_CHANNEL },
    { name = "ghost_1", channel = TALK_VOICE_CHANNEL },
    { name = "ghost_2", channel = TALK_VOICE_CHANNEL },
    { name = "ghost_3", channel = TALK_VOICE_CHANNEL },
    { name = "attacked_1", channel = ATTACK_VOICE_CHANNEL },
    { name = "attacked_2", channel = ATTACK_VOICE_CHANNEL },
    { name = "attacked_3", channel = ATTACK_VOICE_CHANNEL },
    { name = "christmas_carol", channel = DEATH_VOICE_CHANNEL },
    { name = "death", channel = DEATH_VOICE_CHANNEL },
    { name = "do_emote", channel = TALK_VOICE_CHANNEL },
    { name = "drown_in_water", channel = UPGRADE_VOICE_CHANNEL },
    { name = "feel_sleepy", channel = UPGRADE_VOICE_CHANNEL },
    { name = "pose", channel = UPGRADE_VOICE_CHANNEL },
    { name = "ghost_4", channel = UPGRADE_VOICE_CHANNEL },
    { name = "ghost_5", channel = TALK_VOICE_CHANNEL },
    { name = "yawn", channel = TALK_VOICE_CHANNEL },
}

local VOICE_IDS = {}
for id, definition in ipairs(VOICE_DEFINITIONS) do
    VOICE_IDS[definition.name] = id
end

local function IsKeiVoiceSide(inst)
    return inst ~= nil
        and inst:HasTag("kei")
        and TheWorld ~= nil
        and TheWorld.ismastersim
end

local function IsKeiIdle(inst)
    return IsKeiVoiceSide(inst)
        and not inst:HasTag("playerghost")
        and inst.sg ~= nil
        and inst.sg:HasStateTag("idle")
        and not inst:HasTag("busy")
        and not inst:HasTag("notalking")
end

local function StopKeiVoices(inst)
    if inst ~= nil and inst.SoundEmitter ~= nil then
        inst.SoundEmitter:KillSound(VOICE_CHANNEL)
        -- Stop channels used by earlier versions after a hot reload.
        inst.SoundEmitter:KillSound(TALK_VOICE_CHANNEL)
        inst.SoundEmitter:KillSound(ATTACK_VOICE_CHANNEL)
        inst.SoundEmitter:KillSound(UPGRADE_VOICE_CHANNEL)
        inst.SoundEmitter:KillSound(HIT_VOICE_CHANNEL)
        inst.SoundEmitter:KillSound(DEATH_VOICE_CHANNEL)
    end
    if inst ~= nil then
        inst._kei_voice_kind = nil
        inst._kei_voice_priority = nil
    end
end

local function QueueVoice(inst, voice, channel, priority, kind, sound_root)
    if not IsKeiVoiceSide(inst) or not inst:IsValid() then
        return false
    end
    local voice_id = VOICE_IDS[voice]
    if voice_id == nil and sound_root ~= HIT_SOUND_ROOT then
        return false
    end

    if inst.SoundEmitter ~= nil then
        StopKeiVoices(inst)
        inst._kei_voice_kind = kind
        inst._kei_voice_priority = priority
        inst.SoundEmitter:PlaySound(Sound(voice, sound_root), VOICE_CHANNEL, 0.3)
        return true
    end
    return false
end

local function CancelCombatVoice(inst)
    if inst ~= nil and inst._kei_combat_voice_task ~= nil then
        inst._kei_combat_voice_task:Cancel()
        inst._kei_combat_voice_task = nil
    end
end

local function GetRandomVoiceInterval(min_interval, max_interval)
    return min_interval + math.random() * (max_interval - min_interval)
end

local function PlayUpgradeVoice(inst, unlock_count)
    if IsKeiVoiceSide(inst) then
        CancelCombatVoice(inst)
        QueueVoice(
            inst,
            UPGRADE_VOICES[((unlock_count - 1) % #UPGRADE_VOICES) + 1],
            UPGRADE_VOICE_CHANNEL,
            VOICE_PRIORITY_SPECIAL,
            "special"
        )
    end
end

local function PlayRegularTalk(inst)
    if IsKeiIdle(inst)
        and inst._kei_combat_voice_task == nil
        and (inst._kei_combat_voice_lock_until == nil
            or GetTime() >= inst._kei_combat_voice_lock_until)
        and (inst._kei_regular_voice_cooldown_until == nil
            or GetTime() >= inst._kei_regular_voice_cooldown_until)
    then
        local played = QueueVoice(
            inst,
            REGULAR_TALK_VOICES[math.random(#REGULAR_TALK_VOICES)],
            TALK_VOICE_CHANNEL,
            VOICE_PRIORITY_REGULAR,
            "regular"
        )
        if played then
            inst._kei_regular_voice_cooldown_until = GetTime()
                + GetRandomVoiceInterval(REGULAR_VOICE_MIN_INTERVAL, REGULAR_VOICE_MAX_INTERVAL)
        end
    end
end

local function PlayActionTalk(inst)
    if not IsKeiVoiceSide(inst)
        or inst:HasTag("playerghost")
        or inst:HasTag("notalking")
        or (inst._kei_action_voice_cooldown_until ~= nil
            and GetTime() < inst._kei_action_voice_cooldown_until)
    then
        return
    end

    local played = QueueVoice(
        inst,
        REGULAR_TALK_VOICES[math.random(#REGULAR_TALK_VOICES)],
        TALK_VOICE_CHANNEL,
        VOICE_PRIORITY_REGULAR,
        "action"
    )
    if played then
        inst._kei_action_voice_cooldown_until = GetTime()
            + GetRandomVoiceInterval(ACTION_VOICE_MIN_INTERVAL, ACTION_VOICE_MAX_INTERVAL)
    end
end

local function ScheduleCombatVoice(inst, voice, sound_root)
    if not IsKeiVoiceSide(inst) or inst:HasTag("playerghost") then
        return
    end
    CancelCombatVoice(inst)

    -- Combat has priority over regular speech, so silence a regular line as
    -- soon as combat starts. The cooldown is checked at the event itself;
    -- there must be no delayed task that can speak after combat has ended.
    local now = GetTime()
    local next_allowed = inst._kei_next_combat_voice_time or 0
    if now < next_allowed then
        return
    end

    if inst._kei_voice_kind == "regular" then
        StopKeiVoices(inst)
    end

    inst._kei_last_combat_voice_time = now
    inst._kei_next_combat_voice_time = now
        + COMBAT_VOICE_MIN_INTERVAL
        + math.random() * (COMBAT_VOICE_MAX_INTERVAL - COMBAT_VOICE_MIN_INTERVAL)
    inst._kei_combat_voice_lock_until = now + COMBAT_VOICE_REGULAR_LOCK
    QueueVoice(inst, voice, ATTACK_VOICE_CHANNEL, VOICE_PRIORITY_COMBAT, "combat", sound_root)
end

local function PlayHitVoice(inst)
    if IsKeiVoiceSide(inst) and not inst:HasTag("playerghost") then
        ScheduleCombatVoice(
            inst,
            HIT_VOICES[math.random(#HIT_VOICES)],
            HIT_SOUND_ROOT
        )
    end
end

local function PlayDeathVoice(inst)
    if IsKeiVoiceSide(inst) then
        CancelCombatVoice(inst)
        QueueVoice(
            inst,
            DEATH_VOICES[math.random(#DEATH_VOICES)],
            DEATH_VOICE_CHANNEL,
            VOICE_PRIORITY_SPECIAL,
            "special"
        )
    end
end

local function ScheduleIdleTalk(inst)
    if not IsKeiVoiceSide(inst) or not inst:IsValid() then
        return
    end
    local interval = REGULAR_VOICE_MIN_INTERVAL
        + math.random() * (REGULAR_VOICE_MAX_INTERVAL - REGULAR_VOICE_MIN_INTERVAL)
    inst:DoTaskInTime(interval, function()
        if not IsKeiVoiceSide(inst) or not inst:IsValid() then
            return
        end
        if IsKeiIdle(inst) then
            PlayRegularTalk(inst)
        end
        ScheduleIdleTalk(inst)
    end)
end

local function WrapStateOnEnter(sg, state_name, after_enter)
    local state = sg.states ~= nil and sg.states[state_name] or nil
    if state == nil or state.onenter == nil or state.__kei_voice_wrapped then
        return
    end
    local old_onenter = state.onenter
    state.onenter = function(inst, ...)
        old_onenter(inst, ...)
        after_enter(inst, ...)
    end
    state.__kei_voice_wrapped = true
end

local function AddKeiVoiceStategraphHooks(sg)
    WrapStateOnEnter(sg, "attack", function(inst)
        if IsKeiVoiceSide(inst) and inst.sg:HasStateTag("attack") then
            ScheduleCombatVoice(
                inst,
                ATTACK_VOICES[math.random(#ATTACK_VOICES)]
            )
        end
    end)

end

AddStategraphPostInit("wilson", AddKeiVoiceStategraphHooks)
AddStategraphPostInit("wilson_client", AddKeiVoiceStategraphHooks)

AddPrefabPostInit("kei", function(inst)
    -- Install on both sides: the vanilla emote state invokes SoundEmitter on
    -- the side that is currently simulating the player.
    InstallCarolSoundHook(inst)
    inst._kei_carol_mode = inst._kei_carol_mode or "local"

    if TheWorld ~= nil and TheWorld.ismastersim then
        -- Kei's regular lines are also ambient voice lines, so they do not
        -- depend on another system happening to call Talker:Say first.
        ScheduleIdleTalk(inst)
        -- This is the same hook used by the reference character. It runs on
        -- the master and PlaySound is replicated by the native SoundEmitter.
        if inst.components.talker ~= nil then
            inst.components.talker.ontalkfn = function(owner)
                if not owner:HasTag("playerghost") then
                    -- Talker:Say is used by inspect and other action feedback;
                    -- ambient speech is scheduled separately below.
                    PlayActionTalk(owner)
                end
            end
        end

        inst:ListenForEvent("attacked", PlayHitVoice)
        inst:ListenForEvent("death", PlayDeathVoice)

        local unlock_voice_count = 0
        inst:ListenForEvent("kei_protocol_slot_unlocked", function()
            unlock_voice_count = unlock_voice_count + 1
            PlayUpgradeVoice(inst, unlock_voice_count)
        end)
    end
end)
