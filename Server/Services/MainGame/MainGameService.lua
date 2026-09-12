-- // Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- // Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UIRemotes = Remotes:WaitForChild("UIRemotes")
local MainGameRemotes = Remotes:WaitForChild("MainGameRemotes")

local SubmitButton_RE = UIRemotes:WaitForChild("SubmitButton")
local TopBarTextChange_RE = UIRemotes:WaitForChild("TopBarTextChange")
local LeaveButton_RE = UIRemotes:WaitForChild("LeaveButton")
local GiveUpButton_RE = UIRemotes:WaitForChild("GiveUpButton")
local SetMatchUIVisibility_RE = UIRemotes:WaitForChild("SetMatchUIVisibility")
local ShowNotification_RE = UIRemotes:WaitForChild("ShowNotification")
local SetCamera_RE = MainGameRemotes:WaitForChild("SetCamera")
local ConnectBottleToUtility_RE = MainGameRemotes:WaitForChild("ConnectBottleToUtility")
local TimerEnded_RE = MainGameRemotes:WaitForChild("TimerEnded")
local MoveMade_RE = MainGameRemotes:WaitForChild("MoveMade")
local AttachBottle_RE = MainGameRemotes:WaitForChild("AttachBottle")
local EndMatch_RE = MainGameRemotes:WaitForChild("EndMatch")

-- // Modules
local ServiceFolder = ServerScriptService:WaitForChild("Services"):WaitForChild("MainGame"):WaitForChild("Modules")
local BottleUtils = require(ServiceFolder:WaitForChild("BottleUtils"))
local StandManager = require(ServiceFolder:WaitForChild("StandManager"))
local MatchLogic = require(ServiceFolder:WaitForChild("MatchLogic"))

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Data = Packages:WaitForChild("Data")
local DataService = require(Data:WaitForChild("DataService")).server
local DataHandler = require(ServerScriptService:WaitForChild("Handlers"):WaitForChild("DataHandler"))

local MainHandler = {}
MainHandler.Playing = {}
_G.PlayingTable = MainHandler.Playing -- Global state mapping

--------------------------------------------------------------------------------
-- // UTILITIES & HELPERS
--------------------------------------------------------------------------------

function MainHandler:CleanupPlayer(userId)
	if self.Playing[userId] then
		if self.Playing[userId].BottleStand and self.Playing[userId].BottleStand.Parent then
			self.Playing[userId].BottleStand:Destroy()
		end
		self.Playing[userId] = nil
	end
end

--------------------------------------------------------------------------------
-- // MATCHMAKING ENTRYPOINTS
--------------------------------------------------------------------------------

function MainHandler:StartGame(Model)
	local P1 = Players:GetPlayerByUserId(Model:GetAttribute("Player1"))
	local P2 = Players:GetPlayerByUserId(Model:GetAttribute("Player2"))
	if not P1 or not P2 then return end

	MatchLogic:StartMatch(P1, P2, Model, BottleUtils.NORMAL_MODE_BOTTLES, false)
end

function MainHandler:StartHardGame(Model)
	local P1 = Players:GetPlayerByUserId(Model:GetAttribute("Player1"))
	local P2 = Players:GetPlayerByUserId(Model:GetAttribute("Player2"))
	if not P1 or not P2 then return end

	MatchLogic:StartMatch(P1, P2, Model, BottleUtils.HARD_MODE_BOTTLES, false)
end

function MainHandler:StartAiGame(Model)
	local P1
	if Model:GetAttribute("Player1") then
		P1 = Players:GetPlayerByUserId(Model:GetAttribute("Player1"))
	elseif Model:GetAttribute("Player2") then
		P1 = Players:GetPlayerByUserId(Model:GetAttribute("Player2"))
	else
		warn("There is no player on any of the chair to start match with AI!")
		return
	end

	local char = P1.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or not hum.SeatPart then
		StandManager:EnableMovement(P1)
		return
	end

	MatchLogic:StartMatch(P1, nil, Model, BottleUtils.NORMAL_MODE_BOTTLES, true)
end

function MainHandler:StartHardAiGame(Model)
	local P1
	if Model:GetAttribute("Player1") then
		P1 = Players:GetPlayerByUserId(Model:GetAttribute("Player1"))
	elseif Model:GetAttribute("Player2") then
		P1 = Players:GetPlayerByUserId(Model:GetAttribute("Player2"))
	else
		warn("There is no player on any of the chair to start match with AI!")
		return
	end

	local char = P1.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or not hum.SeatPart then
		StandManager:EnableMovement(P1)
		return
	end

	MatchLogic:StartMatch(P1, nil, Model, BottleUtils.HARD_MODE_BOTTLES, true)
end

--------------------------------------------------------------------------------
-- // EVENT LISTENERS
--------------------------------------------------------------------------------

SubmitButton_RE.OnServerEvent:Connect(function(player)
	MatchLogic:SubmitCombinations(player, MainHandler.Playing)
end)

GiveUpButton_RE.OnServerEvent:Connect(function(player)
	MatchLogic:GiveUp(player, MainHandler.Playing)
end)

MoveMade_RE.OnServerEvent:Connect(function(player, orderNamesArray, swapIndex1, swapIndex2)
	local data = MainHandler.Playing[player.UserId]
	if not data or data.MatchEnding then return end

	-- TIMESTAMP FREEZE CHECK
	local now = os.clock()
	if data.FreezeEndTime and now < data.FreezeEndTime then
		warn("[Security] Ignored MoveMade request from frozen player: " .. player.Name)
		ShowNotification_RE:FireClient(player, "You are frozen and cannot move!", "Error")

		-- Revert move state on the client if swap indices exist
		if data.BottleStand then
			local previousOrder = data.CurrentLowerOrder or data.StartingColorsList
			AttachBottle_RE:FireClient(player, data.BottleStand, "LowerPart", data.Skin, data.BottleCount, previousOrder)
		end
		return
	end

	-- Selection phase validation
	if data.State == "Choosing" then
		if BottleUtils:ValidateBottleOrder(orderNamesArray, data.BottleCount) then
			data.CurrentLowerOrder = orderNamesArray
		else
			warn(string.format("[MainHandler] Invalid arrangement from %s. Resetting.", player.Name))
			data.CurrentLowerOrder = table.clone(data.StartingColorsList)
			AttachBottle_RE:FireClient(player, data.BottleStand, "LowerPart", data.Skin, data.BottleCount, data.CurrentLowerOrder)
		end
		return
	end

	-- Gameplay move routing
	MatchLogic:HandleMoveMade(player, orderNamesArray, MainHandler.Playing)
end)

-- Player Leaving Disconnect Logic
Players.PlayerRemoving:Connect(function(player)
	local data = MainHandler.Playing[player.UserId]
	local aiId = -player.UserId

	if data and data.Mode == "AI" then
		local AiMatch = require(ServiceFolder.Parent:WaitForChild("MatchTypes"):WaitForChild("AiMatch"))
		AiMatch:CleanupMatch(player, MainHandler.Playing, true)
		StandManager:SweepOrphanedStands(MainHandler.Playing)
		return
	end

	if MainHandler.Playing[aiId] then
		MainHandler:CleanupPlayer(aiId)
	end

	if not data or data.MatchEnding then
		MainHandler:CleanupPlayer(player.UserId)
		return
	end

	data.MatchEnding = true
	local opponentId = data.OpponentId
	local opp = Players:GetPlayerByUserId(opponentId)
	local oppData = MainHandler.Playing[opponentId]

	if oppData then
		oppData.MatchEnding = true
	end

	pcall(function()
		DataService:set(player, "Streak", 0)
	end)

	DataHandler.AwardLeave(player)

	if data.Model then
		StandManager:SetBarriers(data.Model, false)
	end

	MainHandler:CleanupPlayer(player.UserId)

	if opp and oppData then
		MainHandler:CleanupPlayer(opponentId)

		if data.Model then
			StandManager:AnnounceWinnerOnBillboard(data.Model, opp.Name)
		end
		DataHandler.AwardWin(opp, data.BottleCount == BottleUtils.HARD_MODE_BOTTLES)

		TopBarTextChange_RE:FireClient(opp, true, player.Name .. " left the game! You win.")
		SetMatchUIVisibility_RE:FireClient(opp, true)

		LeaveButton_RE:FireClient(opp, false)
		SubmitButton_RE:FireClient(opp, false)
		GiveUpButton_RE:FireClient(opp, false)
		TimerEnded_RE:FireClient(opp)
		SetCamera_RE:FireClient(opp, "Reset")

		if oppData.BottleStand then
			ConnectBottleToUtility_RE:FireClient(opp, oppData.BottleStand, "LowerPart", false)
		end

		StandManager:EnableMovement(opp)
		StandManager:StandUpAndJump(opp)

		task.delay(1, function()
			EndMatch_RE:FireClient(opp)
		end)
	end

	StandManager:SweepOrphanedStands(MainHandler.Playing)
end)

-- Late Joiner Spectator Attachment
Players.PlayerAdded:Connect(function(newPlayer)
	local processed = {}

	for userId, data in pairs(MainHandler.Playing) do
		if not processed[userId] and data.OpponentId and not processed[data.OpponentId] then
			processed[userId] = true
			processed[data.OpponentId] = true

			local oppData = MainHandler.Playing[data.OpponentId]
			if oppData then
				local ownOrder = data.CurrentLowerOrder or data.StartingColorsList
				AttachBottle_RE:FireClient(newPlayer, data.BottleStand, "LowerPart", data.Skin, data.BottleCount, ownOrder)

				local oppOrder = oppData.CurrentLowerOrder or oppData.StartingColorsList
				AttachBottle_RE:FireClient(newPlayer, oppData.BottleStand, "LowerPart", oppData.Skin, oppData.BottleCount, oppOrder)
			end
		end
	end
end)

-- Periodic Cleanup
task.spawn(function()
	while true do
		task.wait(30)
		StandManager:SweepOrphanedStands(MainHandler.Playing)
	end
end)

return MainHandler
