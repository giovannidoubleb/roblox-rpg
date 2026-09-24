--[[
	Hit/level-up/damage-taken feedback: floating damage numbers where your
	attacks land, a hit sound, a red screen flash when you take damage, a
	level-up burst (flash + sound + toast), and camera shake + particle
	sparks so every hit reads as satisfying - pure presentation, no change
	to the underlying combat numbers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ToastController = require(script.Parent.ToastController)
local Sfx = require(script.Parent.Parent.Sfx)
local Shake = require(script.Parent.Parent.Shake)
local Particles = require(script.Parent.Parent.Particles)

local FeedbackController = {}

local player = Players.LocalPlayer

local function showDamageNumber(worldPosition: Vector3, amount: number, isCrit: boolean)
	local anchor = Instance.new("Part")
	anchor.Name = "DamageNumberAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CFrame = CFrame.new(worldPosition + Vector3.new(math.random(-10, 10) / 10, 2, math.random(-10, 10) / 10))
	anchor.Parent = Workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 100, 0, 40)
	billboard.AlwaysOnTop = true
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = isCrit and string.format("%d!", amount) or tostring(amount)
	label.Font = Enum.Font.GothamBold
	label.TextSize = isCrit and 26 or 20
	label.TextColor3 = isCrit and Color3.fromRGB(255, 210, 60) or Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.Parent = billboard

	local tween = TweenService:Create(anchor, TweenInfo.new(0.8, Enum.EasingStyle.Quad), {
		CFrame = anchor.CFrame + Vector3.new(0, 3, 0),
	})
	local fade = TweenService:Create(label, TweenInfo.new(0.8), { TextTransparency = 1, TextStrokeTransparency = 1 })
	tween:Play()
	fade:Play()
	fade.Completed:Connect(function()
		anchor:Destroy()
	end)
end

local function buildFlash(color: Color3): (Frame, ScreenGui)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Flash"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	return frame, screenGui
end

local function flashDamage()
	local frame, screenGui = buildFlash(Color3.fromRGB(200, 30, 30))
	local tweenIn = TweenService:Create(frame, TweenInfo.new(0.05), { BackgroundTransparency = 0.75 })
	local tweenOut = TweenService:Create(frame, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
	tweenIn:Play()
	tweenIn.Completed:Connect(function()
		tweenOut:Play()
	end)
	tweenOut.Completed:Connect(function()
		screenGui:Destroy()
	end)
end

local function flashLevelUp()
	local frame, screenGui = buildFlash(Color3.fromRGB(255, 230, 120))
	local tweenIn = TweenService:Create(frame, TweenInfo.new(0.1), { BackgroundTransparency = 0.6 })
	local tweenOut = TweenService:Create(frame, TweenInfo.new(0.8), { BackgroundTransparency = 1 })
	tweenIn:Play()
	tweenIn.Completed:Connect(function()
		tweenOut:Play()
	end)
	tweenOut.Completed:Connect(function()
		screenGui:Destroy()
	end)
end

local function trackDamageTaken(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local lastHealth = humanoid.Health

	humanoid.HealthChanged:Connect(function(newHealth)
		if newHealth < lastHealth then
			flashDamage()
			Shake.Trigger(math.clamp((lastHealth - newHealth) / 40, 0.1, 0.5))
		end
		lastHealth = newHealth
	end)
end

function FeedbackController.Init()
	Remotes.DamageDealt.OnClientEvent:Connect(function(worldPosition, amount, isCrit)
		showDamageNumber(worldPosition, amount, isCrit)
		Sfx.Play(Sfx.Ids.Hit, isCrit and 0.6 or 0.35)
		Particles.Burst(worldPosition, isCrit and Color3.fromRGB(255, 210, 60) or Color3.new(1, 1, 1), isCrit and 14 or 6)
		Shake.Trigger(isCrit and 0.35 or 0.12)
	end)

	Remotes.LevelUp.OnClientEvent:Connect(function(level)
		flashLevelUp()
		Sfx.Play(Sfx.Ids.LevelUp, 0.6)
		Shake.Trigger(0.6)
		if player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				Particles.Burst(root.Position, Color3.fromRGB(255, 220, 120), 30, 12)
			end
		end
		ToastController.Show("Level Up! You are now level " .. level, Color3.fromRGB(255, 220, 120))
	end)

	if player.Character then
		trackDamageTaken(player.Character)
	end
	player.CharacterAdded:Connect(trackDamageTaken)
end

return FeedbackController
