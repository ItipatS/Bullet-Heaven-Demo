local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local std = ReplicatedStorage.std
local ref = require(std.ref)

local cts = require(std.components)
local world = require(std.world)
local Player = cts.Player
local Character = cts.Character

local conn = {}

-- Death is server-authoritative and FINAL until Restart (combat.luau hooks Humanoid.Died and
-- calls LoadCharacter on restart). So Roblox must NOT auto-respawn — otherwise a fall/void death
-- would silently reset the character out from under the GameOver screen. We load the first body
-- ourselves below.
Players.CharacterAutoLoads = false

local function playersAdded(player: Player)
	local e = ref(player.UserId)
	world:set(e, Player, player)
	local characterAdd = player.CharacterAdded
	conn[e] = characterAdd:Connect(function(rig)
		while rig.Parent ~= workspace do
			task.wait()
		end
		world:set(e, Character, rig)
	end)
	if not player.Character then
		-- LoadCharacter YIELDS; this runs as a scheduler system (shared-state generic-for
		-- dispatch = C-call boundary), so it must not yield here → spawn it in a fresh thread.
		task.spawn(function() player:LoadCharacterAsync() end)
	end
end

local function playersRemoved(player: Player) 
	local e = ref(player.UserId)
	world:clear(e)
	local connection = conn[e]
	connection:Disconnect()
	conn[e] = nil
end

local scheduler = require(std.scheduler)
local phases = require(std.phases)
scheduler.SYSTEM(playersAdded, phases.PlayerAdded)
scheduler.SYSTEM(playersRemoved, phases.PlayerRemoved)

-- PlayerAdded race guard (CLAUDE.md): in team-test / fast joins a player can
-- already be connected before this runs, so PlayerAdded never fires for them.
for _, p in Players:GetPlayers() do
	playersAdded(p)
end

return 0