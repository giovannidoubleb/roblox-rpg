--[[
	Lets you set a custom display nickname (consumes a Character Rename
	Token, filtered through TextService server-side) via a small panel
	("N" to toggle), and renders a nametag above every player's head -
	their Nickname if they've set one, their normal display name otherwise.
	Nickname/Cosmetic are replicated as Player attributes (set server-side
	in PlayerDataService) so every client can see them, not just the owner.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local UiKit = require(script.Parent.Parent.UiKit)

local NicknameController = {}

local localPlayer = Players.LocalPlayer

local function attachNameTag(player: Player, character: Model)
	local head = character:WaitForChild("Head", 5)
	if not head then
		return
	end

	local existing = head:FindFirstChild("NicknameTag")
	if existing then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NicknameTag"
	billboard.Size = UDim2.new(0, 160, 0, 26)
	billboard.StudsOffset = Vector3.new(0, 2.6, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = Color3.fromRGB(180, 220, 255)
	label.TextStrokeTransparency = 0.4
	label.Parent = billboard

	local function refreshText()
		local nickname = player:GetAttribute("Nickname")
		label.Text = (typeof(nickname) == "string" and #nickname > 0) and nickname or player.DisplayName
	end

	refreshText()
	player:GetAttributeChangedSignal("Nickname"):Connect(refreshText)
end

local function watchPlayer(player: Player)
	if player.Character then
		attachNameTag(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		attachNameTag(player, character)
	end)
end

local function buildPanel(screenGui: ScreenGui)
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 300, 0, 120)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "Set Nickname (press N to close)"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local textBox = Instance.new("TextBox")
	textBox.Size = UDim2.new(1, -20, 0, 30)
	textBox.Position = UDim2.new(0, 10, 0, 36)
	textBox.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	textBox.TextColor3 = Color3.new(1, 1, 1)
	textBox.Font = Enum.Font.Gotham
	textBox.TextSize = 14
	textBox.PlaceholderText = "Requires a Character Rename Token"
	textBox.ClearTextOnFocus = false
	textBox.Parent = panel
	UiKit.RoundButton(textBox, 4)

	local submit = Instance.new("TextButton")
	submit.Size = UDim2.new(1, -20, 0, 28)
	submit.Position = UDim2.new(0, 10, 0, 74)
	submit.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
	submit.Text = "Set Nickname"
	submit.Font = Enum.Font.GothamBold
	submit.TextSize = 13
	submit.TextColor3 = Color3.new(1, 1, 1)
	submit.Parent = panel
	UiKit.RoundButton(submit)

	submit.MouseButton1Click:Connect(function()
		if #textBox.Text > 0 then
			Remotes.RequestSetNickname:FireServer(textBox.Text)
		end
	end)

	return panel
end

function NicknameController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Nickname"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	local panel = buildPanel(screenGui)

	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)

	ContextActionService:BindAction("ToggleNickname", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.N)
end

return NicknameController
