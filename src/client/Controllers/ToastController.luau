--[[
	Shared toast/notification strip in the top-right corner. Other
	controllers (LootController, NotifyController) call ToastController.Show
	instead of each building their own ScreenGui.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ToastController = {}

local player = Players.LocalPlayer
local container: Frame? = nil

function ToastController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Toasts"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Container"
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -20, 0, 20)
	frame.Size = UDim2.new(0, 240, 1, -20)
	frame.BackgroundTransparency = 1
	frame.Parent = screenGui

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.Parent = frame

	container = frame
end

function ToastController.Show(text: string, color: Color3?)
	if not container then
		return
	end

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 30)
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.Text = text
	label.Parent = container

	task.delay(3, function()
		local tween = TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1, BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		label:Destroy()
	end)
end

return ToastController
