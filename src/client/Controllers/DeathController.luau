--[[
	A real "You Died" screen instead of just watching your character ragdoll
	- fades to dark red with a title on death, fades back out the moment a
	new character spawns (whether that's a normal respawn or an Instant
	Revive Token kicking in).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Sfx = require(script.Parent.Parent.Sfx)

local DeathController = {}

local player = Players.LocalPlayer

function DeathController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Death"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 10
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.new(0.5, 0, 0.4, 0)
	title.Size = UDim2.new(0, 400, 0, 60)
	title.BackgroundTransparency = 1
	title.Text = "YOU DIED"
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 42
	title.TextColor3 = Color3.fromRGB(200, 40, 40)
	title.TextTransparency = 1
	title.Parent = frame

	Remotes.PlayerDied.OnClientEvent:Connect(function()
		Sfx.Play(Sfx.Ids.Death, 0.5)
		TweenService:Create(frame, TweenInfo.new(0.6), { BackgroundTransparency = 0.35 }):Play()
		TweenService:Create(title, TweenInfo.new(0.6), { TextTransparency = 0 }):Play()
	end)

	player.CharacterAdded:Connect(function()
		TweenService:Create(frame, TweenInfo.new(0.8), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(title, TweenInfo.new(0.8), { TextTransparency = 1 }):Play()
	end)
end

return DeathController
