--[[
	Settings panel ("L" to toggle): language picker and a Performance Mode
	toggle. Language choice is sent to the server so it persists across
	sessions (PlayerDataService.Settings.Language); Performance Mode is
	purely client-side rendering cost and doesn't need to be.

	Every other panel's static chrome (titles, buttons, key hints) is built
	once at Init time from Locale.T(...) and re-applied through
	Locale.OnChanged, so switching language here updates the whole UI
	immediately - no rejoin needed.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Localization = require(ReplicatedStorage.Shared.Modules.Localization)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Locale = require(script.Parent.Parent.Locale)
local PerformanceController = require(script.Parent.Parent.PerformanceController)
local UiKit = require(script.Parent.Parent.UiKit)

local SettingsController = {}

local player = Players.LocalPlayer

function SettingsController.Init()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Settings"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 300, 0, 220)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	panel.Parent = screenGui
	UiKit.RoundPanel(panel)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = panel

	local languageLabel = Instance.new("TextLabel")
	languageLabel.Size = UDim2.new(1, -20, 0, 18)
	languageLabel.Position = UDim2.new(0, 10, 0, 36)
	languageLabel.BackgroundTransparency = 1
	languageLabel.TextXAlignment = Enum.TextXAlignment.Left
	languageLabel.Font = Enum.Font.Gotham
	languageLabel.TextSize = 13
	languageLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	languageLabel.Parent = panel

	local languageList = Instance.new("Frame")
	languageList.Position = UDim2.new(0, 10, 0, 58)
	languageList.Size = UDim2.new(1, -20, 0, 96)
	languageList.BackgroundTransparency = 1
	languageList.Parent = panel

	local languageLayout = Instance.new("UIGridLayout")
	languageLayout.CellSize = UDim2.new(0, 84, 0, 28)
	languageLayout.CellPadding = UDim2.new(0, 6, 0, 6)
	languageLayout.Parent = languageList

	local languageButtons: { [string]: TextButton } = {}

	local function refreshLanguageButtons()
		for code, button in languageButtons do
			button.BackgroundColor3 = code == Locale.Get() and Color3.fromRGB(70, 130, 200) or Color3.fromRGB(45, 45, 45)
		end
	end

	for _, code in Localization.Languages do
		local button = Instance.new("TextButton")
		button.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 12
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Text = Localization.LanguageNames[code]
		button.Parent = languageList
		UiKit.RoundButton(button, 6)

		button.MouseButton1Click:Connect(function()
			Locale.Set(code)
			Remotes.RequestSetLanguage:FireServer(code)
			refreshLanguageButtons()
		end)

		languageButtons[code] = button
	end
	refreshLanguageButtons()

	local perfRow = Instance.new("Frame")
	perfRow.Size = UDim2.new(1, -20, 0, 30)
	perfRow.Position = UDim2.new(0, 10, 1, -40)
	perfRow.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	perfRow.Parent = panel

	local perfLabel = Instance.new("TextLabel")
	perfLabel.Size = UDim2.new(1, -70, 1, 0)
	perfLabel.Position = UDim2.new(0, 8, 0, 0)
	perfLabel.BackgroundTransparency = 1
	perfLabel.TextXAlignment = Enum.TextXAlignment.Left
	perfLabel.Font = Enum.Font.Gotham
	perfLabel.TextSize = 12
	perfLabel.TextColor3 = Color3.new(1, 1, 1)
	perfLabel.Parent = perfRow

	local perfToggle = Instance.new("TextButton")
	perfToggle.Size = UDim2.new(0, 60, 0, 22)
	perfToggle.Position = UDim2.new(1, -66, 0, 4)
	perfToggle.Font = Enum.Font.GothamBold
	perfToggle.TextSize = 12
	perfToggle.TextColor3 = Color3.new(1, 1, 1)
	perfToggle.Parent = perfRow
	UiKit.RoundButton(perfToggle, 4)

	local function refreshPerfToggle()
		local low = PerformanceController.IsLowEffects()
		perfToggle.Text = low and Locale.T("OnLabel") or Locale.T("OffLabel")
		perfToggle.BackgroundColor3 = low and Color3.fromRGB(90, 170, 100) or Color3.fromRGB(90, 90, 90)
	end

	perfToggle.MouseButton1Click:Connect(function()
		PerformanceController.SetLowEffects(not PerformanceController.IsLowEffects())
		refreshPerfToggle()
	end)

	local function applyTranslations()
		title.Text = Locale.T("SettingsTitle")
		languageLabel.Text = Locale.T("LanguageLabel")
		perfLabel.Text = Locale.T("PerformanceModeLabel")
		refreshPerfToggle()
	end
	applyTranslations()
	Locale.OnChanged(applyTranslations)
	Locale.OnChanged(refreshLanguageButtons)

	-- Pick up the player's saved language the first time their profile
	-- arrives from the server, so returning players don't see English flash
	-- before switching to their real preference.
	local syncedLanguage = false
	Remotes.PlayerDataUpdated.OnClientEvent:Connect(function(data)
		if not syncedLanguage and data.Settings and typeof(data.Settings.Language) == "string" then
			syncedLanguage = true
			Locale.Set(data.Settings.Language)
		end
	end)

	ContextActionService:BindAction("ToggleSettings", function(_name, inputState)
		if inputState == Enum.UserInputState.Begin then
			panel.Visible = not panel.Visible
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.L)
end

return SettingsController
