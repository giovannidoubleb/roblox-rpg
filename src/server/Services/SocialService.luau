--[[
	Friend-invite reward: when a player joins a server where one of their
	Roblox friends is already playing, both get a one-time gem reward. This
	rewards an actual join, not an invite being sent - Roblox doesn't expose
	"did this specific invite get used" to a game server, and rewarding the
	send itself would be trivial to farm (send-and-cancel repeatedly). A
	shared "play together" moment is both the honest signal and the fun one.

	Idempotent: PlayerDataService.TryRewardFriendJoin records the pair on
	both profiles, so the same two friends grouping up again on a later day
	never re-triggers it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local SocialService = {}

local function waitForProfile(player: Player)
	while player.Parent and not PlayerDataService.Get(player) do
		task.wait(0.5)
	end
	return PlayerDataService.Get(player)
end

local function tryRewardPair(newPlayer: Player, existingPlayer: Player)
	local ok, areFriends = pcall(newPlayer.IsFriendsWith, newPlayer, existingPlayer.UserId)
	if not ok or not areFriends then
		return
	end

	if not PlayerDataService.TryRewardFriendJoin(newPlayer, existingPlayer) then
		return
	end

	local reward = Config.Social.FriendJoinRewardGems
	PlayerDataService.AddGems(newPlayer, reward)
	PlayerDataService.AddGems(existingPlayer, reward)
	Remotes.Notify:FireClient(newPlayer, string.format("You joined %s - +%d gems!", existingPlayer.DisplayName, reward))
	Remotes.Notify:FireClient(existingPlayer, string.format("Your friend %s joined - +%d gems!", newPlayer.DisplayName, reward))
end

local function onPlayerAdded(newPlayer: Player)
	if not waitForProfile(newPlayer) then
		return
	end

	for _, existingPlayer in Players:GetPlayers() do
		if existingPlayer ~= newPlayer then
			task.spawn(tryRewardPair, newPlayer, existingPlayer)
		end
	end
end

function SocialService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return SocialService
