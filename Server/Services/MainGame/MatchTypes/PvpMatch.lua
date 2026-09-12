local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- // CONFIGURATION / TIME LIMITS
local NORMAL_MODE_TIME = 120
local HARD_MODE_TIME = 180

-- // Services & Data
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DataService = require(Packages:WaitForChild("Data").DataService).server
local DataHandler = require(ServerScriptService:WaitForChild("Handlers"):WaitForChild("DataHandler"))
local QuestsHandler = require(ServerScriptService:WaitForChild("Handlers"):WaitForChild("QuestsHandler"))

-- // Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UIRemotes, MainGameRemotes, TutorialRemotes = Remotes:WaitForChild("UIRemotes"), Remotes:WaitForChild("MainGameRemotes"), Remotes:WaitForChild("TutorialRemotes")

local TopBarTextChange_RE = UIRemotes:WaitForChild("TopBarTextChange")
local SetCamera_RE = MainGameRemotes:WaitForChild("SetCamera")
local ConnectBottleToUtility_RE = MainGameRemotes:WaitForChild("ConnectBottleToUtility")
local StartStopwatch_RE = MainGameRemotes:WaitForChild("StartStopwatch")
local SwapVisual_RE = MainGameRemotes:WaitForChild("SwapVisual_RE")
local TimerEnded_RE = MainGameRemotes:WaitForChild("TimerEnded")
local AttachBottle_RE = MainGameRemotes:WaitForChild("AttachBottle")
local SetMatchUIVisibility_RE = UIRemotes:WaitForChild("SetMatchUIVisibility")
local SubmitButton_RE = UIRemotes:WaitForChild("SubmitButton")
local LeaveButton_RE = UIRemotes:WaitForChild("LeaveButton")
local GiveUpButton_RE = UIRemotes:WaitForChild("GiveUpButton")
local FreezePlayer_RE = UIRemotes:WaitForChild("FreezePlayer")
local QuickPlayButton_RE = UIRemotes:WaitForChild("QuickPlayButton")
local EndMatch_RE = MainGameRemotes:WaitForChild("EndMatch")
local UpdateStandVisuals_RE = MainGameRemotes:WaitForChild("UpdateStandVisuals")
local BeginCountdown_RE = MainGameRemotes:WaitForChild("BeginCountdown")
local ShowMatchResults_RE = MainGameRemotes:WaitForChild("ShowMatchResults")

local CheckTutorial_RE = TutorialRemotes:WaitForChild("CheckTutorialStatus")

-- // Utils
local Modules = ServerScriptService:WaitForChild("Services"):WaitForChild("MainGame"):WaitForChild("Modules")
local BottleUtils = require(Modules:WaitForChild("BottleUtils"))
local StandManager = require(Modules:WaitForChild("StandManager"))

local Assets = ReplicatedStorage:WaitForChild("Assets")
local BottleStand = Assets:WaitForChild("BottleStand") :: Model
local TempFolder = workspace:WaitForChild("Temp")

local PvpMatch = {}

--------------------------------------------------------------------------------
-- // HELPER FUNCTIONS
--------------------------------------------------------------------------------

local function SafeCancelThread(thread)
	if thread and typeof(thread) == "thread" then
		local status = coroutine.status(thread)
		if status ~= "dead" and thread ~= coroutine.running() then
			pcall(function()
				task.cancel(thread)
			end)
		end
	end
end

local function IsThreadValid(data, matchId)
	return data 
		and data.Mode == "PVP" 
		and data.MatchId == matchId 
		and not data.MatchEnding 
		and data.Model 
		and data.Model.Parent ~= nil
end

local function CleanUpStands(d1, d2)
	if d1 and d1.BottleStand and d1.BottleStand.Parent then d1.BottleStand:Destroy() end
	if d2 and d2.BottleStand and d2.BottleStand.Parent then d2.BottleStand:Destroy() end
end

local function CheckIsHardMode(bottleCount)
	if BottleUtils.HARD_MODE_BOTTLES then
		return bottleCount == BottleUtils.HARD_MODE_BOTTLES
	elseif BottleUtils.HARD_MODE_COUNT then
		return bottleCount == BottleUtils.HARD_MODE_COUNT
	end
	return typeof(bottleCount) == "number" and bottleCount >= 5
end

--------------------------------------------------------------------------------
-- // PVP MATCH FLOW
--------------------------------------------------------------------------------

function PvpMatch:Start(p1, p2, model, bottleCount, matchId)
	QuickPlayButton_RE:FireClient(p1, false); QuickPlayButton_RE:FireClient(p2, false)
	LeaveButton_RE:FireClient(p1, false); LeaveButton_RE:FireClient(p2, false)
	GiveUpButton_RE:FireClient(p1, false); GiveUpButton_RE:FireClient(p2, false)

	if model:FindFirstChild("BillboardGui") and model.BillboardGui:FindFirstChild("TextLabel") then
		model.BillboardGui.Other.Visible = false
		model.BillboardGui.TextLabel.Visible = false
	end

	StandManager:DisableMovement(p1); StandManager:DisableMovement(p2)
	StandManager:SetBarriers(model, true)

	local TableModel = model:WaitForChild("Table")
	local Stand1, Stand2 = BottleStand:Clone(), BottleStand:Clone()

	local Part1, Part2 = TableModel:WaitForChild("Part1"), TableModel:WaitForChild("Part2")
	Stand1.PrimaryPart.Position = Part1.Position + Vector3.new(Part1.Size.X/2 - Stand1.PrimaryPart.Size.X/2, Part1.Size.Y/2, 0)
	Stand2.PrimaryPart.Position = Part2.Position + Vector3.new(Part2.Size.X/2 - Stand2.PrimaryPart.Size.X/2, Part2.Size.Y/2, 0)

	Stand1.Name, Stand2.Name = p1.Name, p2.Name
	Stand1.Parent, Stand2.Parent = TempFolder, TempFolder

	local p1Skin = DataService:get(p1, "EquippedBottle") or "Default"
	local p2Skin = DataService:get(p2, "EquippedBottle") or "Default"

	local p1ColorSet = BottleUtils:GenerateMasterColorLayout(p1Skin, bottleCount)
	local p2ColorSet = BottleUtils:GenerateMasterColorLayout(p2Skin, bottleCount)

	local playingTable = _G.PlayingTable or {}
	local isHardMode = CheckIsHardMode(bottleCount)

	playingTable[p1.UserId] = {
		Mode = "PVP", State = "Choosing", Turn = "None", MatchId = matchId, Role = "P1",
		OpponentId = p2.UserId, GivenBottleOrder = {}, CompletedTime = 999, Submitted = false,
		BottleStand = Stand1, Skin = p1Skin, MatchEnding = false, GaveUp = false,
		StartingColorsList = table.clone(p1ColorSet), CurrentLowerOrder = table.clone(p1ColorSet),
		Model = model, BottleCount = bottleCount, IsHardMode = isHardMode, TurnThread = nil,
		TurnStartTime = nil
	}

	playingTable[p2.UserId] = {
		Mode = "PVP", State = "Choosing", Turn = "None", MatchId = matchId, Role = "P2",
		OpponentId = p1.UserId, GivenBottleOrder = {}, CompletedTime = 999, Submitted = false,
		BottleStand = Stand2, Skin = p2Skin, MatchEnding = false, GaveUp = false,
		StartingColorsList = table.clone(p2ColorSet), CurrentLowerOrder = table.clone(p2ColorSet),
		Model = model, BottleCount = bottleCount, IsHardMode = isHardMode, TurnThread = nil,
		TurnStartTime = nil
	}

	AttachBottle_RE:FireClient(p1, Stand1, "LowerPart", p1Skin, bottleCount, p1ColorSet)
	AttachBottle_RE:FireClient(p1, Stand2, "LowerPart", p2Skin, bottleCount, p2ColorSet)
	AttachBottle_RE:FireClient(p2, Stand1, "LowerPart", p1Skin, bottleCount, p1ColorSet)
	AttachBottle_RE:FireClient(p2, Stand2, "LowerPart", p2Skin, bottleCount, p2ColorSet)

	StandManager:UpdateSpectatorVisuals(p1, p2, Stand1, "LowerPart", p1Skin, bottleCount, p1ColorSet, false, nil)
	StandManager:UpdateSpectatorVisuals(p1, p2, Stand2, "LowerPart", p2Skin, bottleCount, p2ColorSet, false, nil)

	ConnectBottleToUtility_RE:FireClient(p1, Stand1, "LowerPart", true)
	ConnectBottleToUtility_RE:FireClient(p2, Stand2, "LowerPart", true)

	SetCamera_RE:FireClient(p1, "Switch", Stand1); SetCamera_RE:FireClient(p2, "Switch", Stand2)
	SetMatchUIVisibility_RE:FireClient(p1, false); SetMatchUIVisibility_RE:FireClient(p2, false)

	BeginCountdown_RE:FireClient(p1, "Choose Combinations for Opponent!", 15)
	BeginCountdown_RE:FireClient(p2, "Choose Combinations for Opponent!", 15)

	SubmitButton_RE:FireClient(p1, true); SubmitButton_RE:FireClient(p2, true)

	task.delay(15, function()
		local d1, d2 = playingTable[p1.UserId], playingTable[p2.UserId]
		if d1 and d1.MatchId == matchId and d1.State == "Choosing" and not d1.Submitted and not d1.MatchEnding then 
			self:SubmitCombinations(p1, playingTable) 
		end
		if d2 and d2.MatchId == matchId and d2.State == "Choosing" and not d2.Submitted and not d2.MatchEnding then 
			self:SubmitCombinations(p2, playingTable) 
		end
	end)
end

function PvpMatch:SubmitCombinations(player, playingTable)
	playingTable = playingTable or _G.PlayingTable or {}
	local data = playingTable[player.UserId]
	if not data or data.Mode ~= "PVP" or data.State ~= "Choosing" or data.Submitted or data.MatchEnding then return end

	data.Submitted = true
	data.State = "Submitted"
	SubmitButton_RE:FireClient(player, false)
	TimerEnded_RE:FireClient(player)

	if #data.GivenBottleOrder == 0 then
		data.GivenBottleOrder = table.clone(data.CurrentLowerOrder or data.StartingColorsList)
	end

	local opponentData = playingTable[data.OpponentId]
	local opponentPlayer = Players:GetPlayerByUserId(data.OpponentId)

	if opponentData then
		opponentData.GivenBottleOrder = table.clone(data.GivenBottleOrder)
	end

	ConnectBottleToUtility_RE:FireClient(player, data.BottleStand, "LowerPart", false)

	if opponentData and opponentData.Submitted and not opponentData.MatchEnding then
		data.State = "Playing"
		opponentData.State = "Playing"

		task.delay(0.2, function()
			local currentData1 = playingTable[player.UserId]
			local currentData2 = playingTable[data.OpponentId]

			if currentData1 and not currentData1.MatchEnding then GiveUpButton_RE:FireClient(player, true) end
			if currentData2 and opponentPlayer and not currentData2.MatchEnding then GiveUpButton_RE:FireClient(opponentPlayer, true) end

			local p1First = math.random(1, 2) == 1
			local activePlayer = p1First and player or opponentPlayer
			self:StartTurn(activePlayer, playingTable)
		end)
	else
		TopBarTextChange_RE:FireClient(player, true, "Waiting for opponent to submit...")
	end
end

function PvpMatch:StartTurn(activePlayer, playingTable)
	playingTable = playingTable or _G.PlayingTable or {}
	local data = playingTable[activePlayer.UserId]
	if not data or data.Mode ~= "PVP" or data.MatchEnding then return end

	local opponentData = playingTable[data.OpponentId]
	local opponentPlayer = Players:GetPlayerByUserId(data.OpponentId)

	data.Turn = data.Role
	if opponentData then opponentData.Turn = data.Role end

	data.TurnStartTime = tick()
	local maxTurnTime = data.IsHardMode and HARD_MODE_TIME or NORMAL_MODE_TIME

	if data.GivenBottleOrder and #data.GivenBottleOrder > 0 then
		data.CurrentLowerOrder = BottleUtils:GenerateDerangement(data.GivenBottleOrder)
	else
		data.CurrentLowerOrder = data.CurrentLowerOrder or table.clone(data.StartingColorsList)
	end
	FreezePlayer_RE:FireClient(activePlayer, "Hide")
	AttachBottle_RE:FireClient(
		activePlayer, 
		data.BottleStand, 
		"LowerPart", 
		data.Skin, 
		data.BottleCount, 
		data.CurrentLowerOrder
	)

	if opponentPlayer then
		FreezePlayer_RE:FireClient(opponentPlayer, "Show")
		AttachBottle_RE:FireClient(
			opponentPlayer,
			data.BottleStand,
			"LowerPart",
			data.Skin,
			data.BottleCount,
			data.CurrentLowerOrder
		)
	end

	StandManager:UpdateSpectatorVisuals(
		activePlayer, 
		opponentPlayer, 
		data.BottleStand, 
		"LowerPart", 
		data.Skin, 
		data.BottleCount, 
		data.CurrentLowerOrder, 
		false, 
		nil
	)

	if opponentPlayer and opponentData then
		AttachBottle_RE:FireClient(
			opponentPlayer, 
			data.BottleStand, 
			"UpperPart", 
			data.Skin, 
			data.BottleCount, 
			opponentData.GivenBottleOrder
		)
	end

	SetCamera_RE:FireClient(activePlayer, "Switch", data.BottleStand)
	ConnectBottleToUtility_RE:FireClient(activePlayer, data.BottleStand, "LowerPart", true)

	TopBarTextChange_RE:FireClient(activePlayer, true, "0 / " .. data.BottleCount .. " bottles matched! ⌛")

	if opponentPlayer then
		SetCamera_RE:FireClient(opponentPlayer, "Switch", data.BottleStand)
		ConnectBottleToUtility_RE:FireClient(opponentPlayer, data.BottleStand, "LowerPart", false)
		TopBarTextChange_RE:FireClient(opponentPlayer, true, activePlayer.DisplayName .. "'s Turn!")

		local timeToBeat = (opponentData and opponentData.CompletedTime < 999) and opponentData.CompletedTime or nil
		StartStopwatch_RE:FireClient(activePlayer, timeToBeat)
		StartStopwatch_RE:FireClient(opponentPlayer, timeToBeat)
	end

	SafeCancelThread(data.TurnThread)
	data.TurnThread = task.spawn(function()
		task.wait(maxTurnTime)

		if IsThreadValid(data, data.MatchId) and data.Turn == data.Role and data.CompletedTime == 999 then
			data.CompletedTime = maxTurnTime

			ConnectBottleToUtility_RE:FireClient(activePlayer, data.BottleStand, "LowerPart", false)
			TimerEnded_RE:FireClient(activePlayer)
			if opponentPlayer then TimerEnded_RE:FireClient(opponentPlayer) end

			if opponentData and opponentData.CompletedTime == 999 then
				if opponentPlayer then self:StartTurn(opponentPlayer, playingTable) end
			else
				self:EndMatch(activePlayer, opponentPlayer, data, opponentData, playingTable)
			end
		end
	end)
end

function PvpMatch:HandleMoveMade(player, orderNamesArray, playingTable)
	playingTable = playingTable or _G.PlayingTable or {}
	local data = playingTable[player.UserId]
	if not data or data.Mode ~= "PVP" or data.MatchEnding then return end

	if not data.Submitted then
		if BottleUtils:ValidateBottleOrder(orderNamesArray, data.BottleCount) then
			data.GivenBottleOrder = orderNamesArray
			data.CurrentLowerOrder = orderNamesArray
		else
			warn(string.format("[PvpMatch] Rejected invalid bottle order from %s (%d).", player.Name, player.UserId))
			data.GivenBottleOrder = BottleUtils:GenerateRandomServerOrder(data.BottleCount)
			data.CurrentLowerOrder = table.clone(data.GivenBottleOrder)
			AttachBottle_RE:FireClient(player, data.BottleStand, "LowerPart", data.Skin, data.BottleCount, data.GivenBottleOrder)
			TopBarTextChange_RE:FireClient(player, true, "Your arrangement was invalid — it's been reset.")
		end
		return
	end

	if data.Turn ~= data.Role then return end

	local opponentData = playingTable[data.OpponentId]
	if not opponentData or opponentData.MatchEnding then return end

	local maxTurnTime = data.IsHardMode and HARD_MODE_TIME or NORMAL_MODE_TIME
	local elapsed = tick() - (data.TurnStartTime or tick())

	if elapsed >= maxTurnTime then return end

	local oldOrder = data.CurrentLowerOrder or table.clone(data.StartingColorsList)
	if not BottleUtils:IsSameMultiset(oldOrder, orderNamesArray) then return end
	if not BottleUtils:IsValidSingleSwap(oldOrder, orderNamesArray) then return end

	local idx1, idx2 = nil, nil
	for i = 1, data.BottleCount do
		if oldOrder[i] ~= orderNamesArray[i] then
			if not idx1 then idx1 = i else idx2 = i end
		end
	end

	data.CurrentLowerOrder = table.clone(orderNamesArray)

	local matched = 0
	local targetOrder = data.GivenBottleOrder

	for i = 1, data.BottleCount do
		if data.CurrentLowerOrder[i] == targetOrder[i] then 
			matched += 1 
		end
	end

	local opponentPlayer = Players:GetPlayerByUserId(data.OpponentId)

	if idx1 and idx2 then
		SwapVisual_RE:FireAllClients(player, data.BottleStand, "LowerPart", idx1, idx2)
	end

	TopBarTextChange_RE:FireClient(player, true, matched .. " / " .. data.BottleCount .. " bottles matched! ⌛")
	if opponentPlayer then
		TopBarTextChange_RE:FireClient(opponentPlayer, true, player.DisplayName .. " matched " .. matched .. " / " .. data.BottleCount .. " bottles! ⌛")
	end

	if matched == data.BottleCount then
		SafeCancelThread(data.TurnThread)
		data.TurnThread = nil

		data.CompletedTime = math.min(elapsed, maxTurnTime)
		ConnectBottleToUtility_RE:FireClient(player, data.BottleStand, "LowerPart", false)
		TimerEnded_RE:FireClient(player)
		if opponentPlayer then TimerEnded_RE:FireClient(opponentPlayer) end

		if opponentData.CompletedTime == 999 then
			if opponentPlayer then self:StartTurn(opponentPlayer, playingTable) end
		else
			self:EndMatch(player, opponentPlayer, data, opponentData, playingTable)
		end
	end
end

function PvpMatch:GiveUp(player, playingTable)
	playingTable = playingTable or _G.PlayingTable or {}
	local data = playingTable[player.UserId]
	if not data or data.Mode ~= "PVP" or not data.Submitted or data.MatchEnding then return end

	local maxTurnTime = data.IsHardMode and HARD_MODE_TIME or NORMAL_MODE_TIME
	local opponentData = playingTable[data.OpponentId]
	local opponentPlayer = Players:GetPlayerByUserId(data.OpponentId)

	SafeCancelThread(data.TurnThread)
	data.TurnThread = nil

	if data.CompletedTime == 999 and data.TurnStartTime then
		data.CompletedTime = math.min(tick() - data.TurnStartTime, maxTurnTime)
	end

	if opponentData and opponentData.CompletedTime == 999 and opponentData.TurnStartTime then
		opponentData.CompletedTime = math.min(tick() - opponentData.TurnStartTime, maxTurnTime)
	end

	data.GaveUp = true

	self:EndMatch(player, opponentPlayer, data, opponentData, playingTable)
end

function PvpMatch:LeaveMatch(player, playingTable)
	playingTable = playingTable or _G.PlayingTable or {}
	local data = playingTable[player.UserId]
	if data then
		SafeCancelThread(data.TurnThread)
		data.TurnThread = nil
		DataHandler.AwardLeave(player)
	end

	local opponentPlayer = data and Players:GetPlayerByUserId(data.OpponentId)
	local opponentData = data and playingTable[data.OpponentId]

	if opponentPlayer and opponentData then
		SafeCancelThread(opponentData.TurnThread)
		opponentData.TurnThread = nil
		data.GaveUp = true
		self:EndMatch(player, opponentPlayer, data, opponentData, playingTable)
	end
end

function PvpMatch:EndMatch(p1, p2, d1, d2, playingTable)
	playingTable = playingTable or _G.PlayingTable or {}
	if not d1 or d1.MatchEnding or (d2 and d2.MatchEnding) then return end
	d1.MatchEnding = true
	if d2 then d2.MatchEnding = true end

	SafeCancelThread(d1.TurnThread)
	d1.TurnThread = nil
	if d2 then
		SafeCancelThread(d2.TurnThread)
		d2.TurnThread = nil
	end

	local isHardMode = d1.IsHardMode
	if isHardMode == nil then
		isHardMode = CheckIsHardMode(d1.BottleCount)
	end

	local p1Won = false

	local p1Time = d1.CompletedTime or 999
	local p2Time = d2 and d2.CompletedTime or 999

	if d1.GaveUp then
		p1Won = false
	elseif d2 and d2.GaveUp then
		p1Won = true
	elseif p1Time == p2Time then
		p1Won = math.random(1, 2) == 1
	else
		p1Won = p1Time < p2Time
	end

	if p1Won then
		DataHandler.AwardWin(p1, isHardMode)
		if p2 then
			DataHandler.AwardLoss(p2, isHardMode)
		end

		TopBarTextChange_RE:FireClient(p1, true, "You Won!")
		if p2 then TopBarTextChange_RE:FireClient(p2, true, p1.DisplayName .. " Won!") end
		if d1.Model then StandManager:AnnounceWinnerOnBillboard(d1.Model, p1.Name) end
	else
		DataHandler.AwardLoss(p1, isHardMode)
		if p2 then
			DataHandler.AwardWin(p2, isHardMode)
		end

		if p2 then TopBarTextChange_RE:FireClient(p2, true, "You Won!") end
		TopBarTextChange_RE:FireClient(p1, true, (p2 and p2.DisplayName or "Opponent") .. " Won!")
		if p2 and d1.Model then
			StandManager:AnnounceWinnerOnBillboard(d1.Model, p2.Name)
		end
	end

	QuestsHandler.OnMatchEnded(p1, p2)
	QuestsHandler.OnMatchEnded(p2, p1)

	GiveUpButton_RE:FireClient(p1, false)
	if p2 then GiveUpButton_RE:FireClient(p2, false) end

	local p1Streak = DataService:get(p1, "Streak") or 0
	local p2Streak = p2 and (DataService:get(p2, "Streak") or 0) or 0

	local p1Result = {
		IsWinner = p1Won,
		MyTime = (d1.CompletedTime and d1.CompletedTime < 999) and d1.CompletedTime or 0,
		MyStreak = p1Streak,
		MyReward = p1Won and (isHardMode and 300 or 100) or (isHardMode and 50 or 20),
		OpponentUserId = p2 and p2.UserId or -1,
		OpponentDisplayName = p2 and p2.DisplayName or "Opponent",
		OpponentTime = (d2 and d2.CompletedTime and d2.CompletedTime < 999) and d2.CompletedTime or 0,
		OpponentStreak = p2Streak,
	}

	ShowMatchResults_RE:FireClient(p1, p1Result)

	if p2 and d2 then
		local p2Result = {
			IsWinner = not p1Won,
			MyTime = (d2.CompletedTime and d2.CompletedTime < 999) and d2.CompletedTime or 0,
			MyStreak = p2Streak,
			MyReward = (not p1Won) and (isHardMode and 300 or 100) or (isHardMode and 50 or 20),
			OpponentUserId = p1.UserId,
			OpponentDisplayName = p1.DisplayName,
			OpponentTime = (d1.CompletedTime and d1.CompletedTime < 999) and d1.CompletedTime or 0,
			OpponentStreak = p1Streak,
		}
		ShowMatchResults_RE:FireClient(p2, p2Result)
	end

	EndMatch_RE:FireClient(p1, p1Won)
	if p2 then EndMatch_RE:FireClient(p2, not p1Won) end

	task.wait()

	if not DataService:get(p1, "hasCompletedTutorial") then
		DataService:set(p1, "hasCompletedTutorial", true)
		CheckTutorial_RE:FireClient(p1, true)
	end

	if p2 and not DataService:get(p2, "hasCompletedTutorial") then
		DataService:set(p2, "hasCompletedTutorial", true)
		CheckTutorial_RE:FireClient(p2, true)
	end

	if p1 then
		SetCamera_RE:FireClient(p1, "Reset")
		SetMatchUIVisibility_RE:FireClient(p1, true)
		TopBarTextChange_RE:FireClient(p1, false, "...")
		StandManager:EnableMovement(p1)
		StandManager:StandUpAndJump(p1)	
	end

	if p2 then
		SetCamera_RE:FireClient(p2, "Reset")
		SetMatchUIVisibility_RE:FireClient(p2, true)
		TopBarTextChange_RE:FireClient(p2, false, "...")
		StandManager:EnableMovement(p2)
		StandManager:StandUpAndJump(p2)
	end

	if d1.Model then
		StandManager:SetBarriers(d1.Model, false)
		d1.Model:SetAttribute("EndedNormally", true)
	end

	CleanUpStands(d1, d2)

	playingTable[p1.UserId] = nil
	if p2 then playingTable[p2.UserId] = nil end
end

return PvpMatch
