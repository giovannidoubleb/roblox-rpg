--[[
	Small always-visible "Invite a Friend" button that opens Roblox's native
	friend-invite prompt. The actual reward is granted server-side
	(SocialService) when the invited friend really joins - this is just the
	entry point for sending the invite in the first place.
]]

local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")

local Locale = require(script.Parent.Parent.Locale)
local ToastController = require(script.Parent.ToastController)
local UiKit = require(script.Parent.Parent.UiKit)

local InviteController = {}

local player = Players.LocalPlayer

function InviteController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Invite"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local button = Instance.new("TextButton")
	button.Name = "InviteButton"
	button.AnchorPoint = Vector2.new(0, 0)
	button.Position = UDim2.new(0, 20, 0, 20)
	button.Size = UDim2.new(0, 150, 0, 32)
	button.BackgroundColor3 = Color3.fromRGB(230, 150, 40)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Text = "🎉 " .. Locale.T("InviteFriendButton")
	button.Parent = screenGui
	UiKit.RoundButton(button, 8)

	Locale.OnChanged(function()
		button.Text = "🎉 " .. Locale.T("InviteFriendButton")
	end)

	button.MouseButton1Click:Connect(function()
		local canInviteOk, canInvite = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
		if not canInviteOk or not canInvite then
			ToastController.Show(Locale.T("InviteUnavailable"))
			return
		end

		pcall(SocialService.PromptGameInvite, SocialService, player)
	end)
end

return InviteController
