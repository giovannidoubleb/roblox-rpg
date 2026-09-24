--[[
	Lightweight, code-owned localization for this game's UI chrome (panel
	titles, buttons, key hints, HUD labels, onboarding copy). This is
	intentionally NOT Roblox's LocalizationService/auto-translate pipeline
	(that needs a CSV uploaded to the experience's Localization Tables in
	Studio, which this environment can't author) - it's a plain string
	table keyed by a short language code, switched instantly client-side by
	SettingsController and persisted per player via PlayerDataService.

	Scope: static UI chrome only. Server-generated toast text (quest
	complete, purchase results, etc in Remotes.Notify) stays English for
	now - translating those would mean sending message keys instead of
	final strings from every server call site, which is a larger followup,
	not a UI setting.
]]

local Localization = {}

Localization.Languages = { "en", "es", "fr", "de", "pt" }

Localization.LanguageNames = {
	en = "English",
	es = "Español",
	fr = "Français",
	de = "Deutsch",
	pt = "Português",
}

local STRINGS = {
	en = {
		SettingsTitle = "Settings (press L to close)",
		LanguageLabel = "Language",
		PerformanceModeLabel = "Performance Mode (fewer effects)",
		OnLabel = "ON",
		OffLabel = "OFF",
		InviteFriendButton = "Invite a Friend",
		InviteUnavailable = "Game invites aren't available right now.",
		DailyTitle = "Daily (press J to close)",
		ClaimDailyButton = "Claim Daily Login",
		StreakLabel = "Streak: %d days   Keys: %d / %d",
		SkillsTitle = "Skills (press K to close)",
		UnspentPoints = "Unspent points: %d",
		RespecButton = "Respec (uses a Stat Respec Token)",
		ZonesTitle = "Travel (press M to close)",
		TravelButton = "Travel",
		CraftingTitle = "Crafting (press C to close)",
		CraftButton = "Craft",
		NicknameTitle = "Set Nickname (press N to close)",
		SetNicknameButton = "Set Nickname",
		MerchantTitle = "Merchant (press B to close)",
		WelcomeTitle = "Welcome to the Wilds!",
		WelcomeTip1 = "Left click / tap to attack the nearest enemy",
		WelcomeTip2 = "Press 1 / 2 for skills, R for your ultimate",
		WelcomeTip3 = "Follow the glowing marker to your first fight",
	},
	es = {
		SettingsTitle = "Ajustes (pulsa L para cerrar)",
		LanguageLabel = "Idioma",
		PerformanceModeLabel = "Modo rendimiento (menos efectos)",
		OnLabel = "ACTIVADO",
		OffLabel = "DESACTIVADO",
		InviteFriendButton = "Invitar a un amigo",
		InviteUnavailable = "Las invitaciones no están disponibles ahora mismo.",
		DailyTitle = "Diario (pulsa J para cerrar)",
		ClaimDailyButton = "Reclamar recompensa diaria",
		StreakLabel = "Racha: %d días   Llaves: %d / %d",
		SkillsTitle = "Habilidades (pulsa K para cerrar)",
		UnspentPoints = "Puntos sin usar: %d",
		RespecButton = "Reasignar (usa un Token de Reasignación)",
		ZonesTitle = "Viajar (pulsa M para cerrar)",
		TravelButton = "Viajar",
		CraftingTitle = "Crafteo (pulsa C para cerrar)",
		CraftButton = "Craftear",
		NicknameTitle = "Poner apodo (pulsa N para cerrar)",
		SetNicknameButton = "Poner apodo",
		MerchantTitle = "Mercader (pulsa B para cerrar)",
		WelcomeTitle = "¡Bienvenido a las Tierras Salvajes!",
		WelcomeTip1 = "Clic izquierdo / toca para atacar al enemigo más cercano",
		WelcomeTip2 = "Pulsa 1 / 2 para habilidades, R para tu definitiva",
		WelcomeTip3 = "Sigue el marcador brillante hasta tu primera pelea",
	},
	fr = {
		SettingsTitle = "Paramètres (appuyez sur L pour fermer)",
		LanguageLabel = "Langue",
		PerformanceModeLabel = "Mode performance (moins d'effets)",
		OnLabel = "ACTIVÉ",
		OffLabel = "DÉSACTIVÉ",
		InviteFriendButton = "Inviter un ami",
		InviteUnavailable = "Les invitations ne sont pas disponibles pour le moment.",
		DailyTitle = "Quotidien (appuyez sur J pour fermer)",
		ClaimDailyButton = "Réclamer la récompense quotidienne",
		StreakLabel = "Série : %d jours   Clés : %d / %d",
		SkillsTitle = "Compétences (appuyez sur K pour fermer)",
		UnspentPoints = "Points non dépensés : %d",
		RespecButton = "Réinitialiser (utilise un Jeton de Réinitialisation)",
		ZonesTitle = "Voyage (appuyez sur M pour fermer)",
		TravelButton = "Voyager",
		CraftingTitle = "Artisanat (appuyez sur C pour fermer)",
		CraftButton = "Fabriquer",
		NicknameTitle = "Définir un surnom (appuyez sur N pour fermer)",
		SetNicknameButton = "Définir le surnom",
		MerchantTitle = "Marchand (appuyez sur B pour fermer)",
		WelcomeTitle = "Bienvenue dans les Terres Sauvages !",
		WelcomeTip1 = "Clic gauche / appui pour attaquer l'ennemi le plus proche",
		WelcomeTip2 = "1 / 2 pour les compétences, R pour l'ultime",
		WelcomeTip3 = "Suivez le repère lumineux jusqu'à votre premier combat",
	},
	de = {
		SettingsTitle = "Einstellungen (L zum Schließen)",
		LanguageLabel = "Sprache",
		PerformanceModeLabel = "Leistungsmodus (weniger Effekte)",
		OnLabel = "AN",
		OffLabel = "AUS",
		InviteFriendButton = "Freund einladen",
		InviteUnavailable = "Einladungen sind gerade nicht verfügbar.",
		DailyTitle = "Täglich (J zum Schließen)",
		ClaimDailyButton = "Tägliche Belohnung abholen",
		StreakLabel = "Serie: %d Tage   Schlüssel: %d / %d",
		SkillsTitle = "Fähigkeiten (K zum Schließen)",
		UnspentPoints = "Unverbrauchte Punkte: %d",
		RespecButton = "Zurücksetzen (verbraucht ein Respec-Token)",
		ZonesTitle = "Reisen (M zum Schließen)",
		TravelButton = "Reisen",
		CraftingTitle = "Handwerk (C zum Schließen)",
		CraftButton = "Herstellen",
		NicknameTitle = "Spitznamen setzen (N zum Schließen)",
		SetNicknameButton = "Spitznamen setzen",
		MerchantTitle = "Händler (B zum Schließen)",
		WelcomeTitle = "Willkommen in der Wildnis!",
		WelcomeTip1 = "Linksklick / Tippen greift den nächsten Gegner an",
		WelcomeTip2 = "1 / 2 für Fähigkeiten, R für deine Ultimate",
		WelcomeTip3 = "Folge der leuchtenden Markierung zu deinem ersten Kampf",
	},
	pt = {
		SettingsTitle = "Configurações (pressione L para fechar)",
		LanguageLabel = "Idioma",
		PerformanceModeLabel = "Modo desempenho (menos efeitos)",
		OnLabel = "LIGADO",
		OffLabel = "DESLIGADO",
		InviteFriendButton = "Convidar um amigo",
		InviteUnavailable = "Convites não estão disponíveis agora.",
		DailyTitle = "Diário (pressione J para fechar)",
		ClaimDailyButton = "Resgatar recompensa diária",
		StreakLabel = "Sequência: %d dias   Chaves: %d / %d",
		SkillsTitle = "Habilidades (pressione K para fechar)",
		UnspentPoints = "Pontos não usados: %d",
		RespecButton = "Redefinir (usa um Token de Redefinição)",
		ZonesTitle = "Viagem (pressione M para fechar)",
		TravelButton = "Viajar",
		CraftingTitle = "Criação (pressione C para fechar)",
		CraftButton = "Criar",
		NicknameTitle = "Definir apelido (pressione N para fechar)",
		SetNicknameButton = "Definir apelido",
		MerchantTitle = "Mercador (pressione B para fechar)",
		WelcomeTitle = "Bem-vindo às Terras Selvagens!",
		WelcomeTip1 = "Clique esquerdo / toque para atacar o inimigo mais próximo",
		WelcomeTip2 = "1 / 2 para habilidades, R para sua ultimate",
		WelcomeTip3 = "Siga o marcador brilhante até sua primeira luta",
	},
}

-- Every non-English table only needs to hold what differs; anything missing
-- falls back to English rather than showing a blank/broken label.
function Localization.Get(languageCode: string, key: string): string
	local table_ = STRINGS[languageCode]
	local value = table_ and table_[key]
	if value then
		return value
	end
	return STRINGS.en[key] or key
end

return Localization
