--------------------------------------------------------------------------------
-- BagPraudit - "what is all this stuff in my bags?"
--
-- Scans every bag slot, classifies each item with returning-player heuristics,
-- and presents a review window. Nothing is ever sold or deleted automatically:
-- selling happens only from the button while a merchant is open, deletion only
-- from a per-item button with a confirmation popup.
--
-- Verdicts:
--   SELL    safe to vendor (grey junk, expired consumables, known recipes...)
--   DELETE  worthless AND has no vendor value (conjured food, no-value greys)
--   REVIEW  probably junk but a human should look (orphaned quest items,
--           holiday items, uncollected transmog, last-expansion consumables)
--   BANK    sentimental / hard or impossible to reacquire - park it in the
--           bank (or warband bank) instead of deleting
--   AH      worth listing on the auction house instead of vendoring
--   KEEP    current-content or account-bound; left alone
--------------------------------------------------------------------------------

local ADDON_NAME = ...
local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata
	and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "?"

local BT = CreateFrame("Frame", "BagPrauditEventFrame")
BT.results = {}
BT.merchantOpen = false

-- ---------------------------------------------------------------------------
-- Constants / environment
-- ---------------------------------------------------------------------------

-- Item expansion IDs and GetExpansionLevel() share the same enum family, so a
-- runtime comparison stays correct across future patches without hardcoding.
local CUR_XPAC = (GetExpansionLevel and GetExpansionLevel())
	or LE_EXPANSION_LEVEL_CURRENT or 0

local POOR = (Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
local LEGENDARY = (Enum.ItemQuality and Enum.ItemQuality.Legendary) or 5
local ARTIFACT = (Enum.ItemQuality and Enum.ItemQuality.Artifact) or 6
local HEIRLOOM = (Enum.ItemQuality and Enum.ItemQuality.Heirloom) or 7

-- Item class IDs (Enum.ItemClass)
local CLASS_CONSUMABLE = 0
local CLASS_GEM        = 3
local CLASS_REAGENT    = 5  -- legacy "Reagent" class
local CLASS_TRADEGOODS = 7
local CLASS_ENHANCE    = 8
local CLASS_RECIPE     = 9
local CLASS_QUEST      = 12
local CLASS_MISC       = 15
local CLASS_GLYPH      = 16
local CLASS_BATTLEPET  = 17
local CLASS_WOWTOKEN   = 18
local CLASS_PROFESSION = 19

local MISC_SUB_PET     = 2
local MISC_SUB_HOLIDAY = 3
local MISC_SUB_MOUNT   = 5

-- Account-bound Enum.ItemBind values (warbound and friends)
local ACCOUNT_BINDS = { [7] = true, [8] = true, [9] = true }

local VERDICT_ORDER = { SELL = 1, DELETE = 2, REVIEW = 3, BANK = 4, AH = 5, KEEP = 6 }
local VERDICT_COLOR = {
	SELL   = "ffffd100",
	DELETE = "ffff4040",
	REVIEW = "ffff8000",
	BANK   = "ffa335ee",
	AH     = "ff40c0ff",
	KEEP   = "ff40ff40",
}
local VERDICT_LABEL = {
	SELL   = "Sell at vendor",
	DELETE = "Safe to delete (no vendor value)",
	REVIEW = "Review by hand",
	BANK   = "Bank it (sentimental / hard to reacquire)",
	AH     = "Auction house candidates",
	KEEP   = "Keep",
}

-- Items we always keep regardless of heuristics
local BUILTIN_KEEP = {
	[6948] = true, -- Hearthstone
}

-- Sub-groups for the big REVIEW pile, matched against stable substrings of the
-- reason strings above so like items can be handled in batches.
local TAG_PATTERNS = {
	{ "quest item",           "Quest leftovers" },
	{ "starts a quest",       "Unstarted quests" },
	{ "utility/novelty",      "Utility & novelty gadgets" },
	{ "EQUIP IT ONCE",        "Equip for transmog, then sell" },
	{ "not collectible by",   "Mog locked to another class" },
	{ "outdated soulbound",   "Old gear - check transmog" },
	{ "BOUND crafting",       "Bound crafting materials" },
	{ "token/teleport/curio", "Old tokens & curios" },
	{ "tabard/shirt",         "Tabards & shirts" },
	{ "last-expansion",       "Last-expansion consumables" },
	{ "openable",             "Openable containers" },
	{ "holiday",              "Holiday items" },
	{ "no current-content",   "Misc old items" },
}

local function ReviewTag(reason)
	for _, p in ipairs(TAG_PATTERNS) do
		if reason and reason:find(p[1], 1, true) then return p[2] end
	end
	return "Other"
end

local function xpacName(id)
	return _G["EXPANSION_NAME" .. tostring(id)] or ("expansion " .. tostring(id))
end

local function isOldXpac(expacID)
	return expacID ~= nil and expacID ~= 254 and expacID < CUR_XPAC
end

local function isPrevXpac(expacID)
	return expacID ~= nil and expacID == CUR_XPAC - 1
end

local function chat(msg)
	print("|cff6699ffBagPraudit:|r " .. msg)
end

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------

local function InitDB()
	BagPrauditDB = BagPrauditDB or {}
	BagPrauditDB.keepList = BagPrauditDB.keepList or {}
	BagPrauditDB.settings = BagPrauditDB.settings or {}
	if BagPrauditDB.settings.sellBatch12 == nil then
		BagPrauditDB.settings.sellBatch12 = true -- stay within the 12-slot buyback window
	end
	if BagPrauditDB.settings.showKeep == nil then
		BagPrauditDB.settings.showKeep = false
	end
	BagPrauditDB.settings.collapsed = BagPrauditDB.settings.collapsed or {}
	BT.db = BagPrauditDB
end

-- ---------------------------------------------------------------------------
-- Tooltip scanning (C_TooltipInfo, 10.0+ / verified present in 12.x)
-- ---------------------------------------------------------------------------

local function GetTooltipLines(bag, slot)
	local lines = {}
	if not (C_TooltipInfo and C_TooltipInfo.GetBagItem) then return lines end
	local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then
		return lines
	end
	for _, line in ipairs(data.lines) do
		local text = line.leftText
		if not text and TooltipUtil and TooltipUtil.SurfaceArgs then
			pcall(TooltipUtil.SurfaceArgs, line)
			text = line.leftText
		end
		if type(text) == "string" and text ~= "" then
			lines[#lines + 1] = text
		end
	end
	return lines
end

local function TooltipHas(lines, needle)
	if not needle then return false end
	for _, text in ipairs(lines) do
		if text == needle or text:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function TooltipHasExact(lines, needle)
	if not needle then return false end
	for _, text in ipairs(lines) do
		if text == needle then return true end
	end
	return false
end

-- Slots with no transmog appearance: nothing is lost by selling these.
local NO_APPEARANCE_EQUIP = {
	INVTYPE_FINGER = true, INVTYPE_TRINKET = true, INVTYPE_NECK = true,
}

-- Returns "collected" | "learnable" | "notforclass" | "uncollected" | nil
local function AppearanceStatus(link)
	if not (link and C_TransmogCollection
		and C_TransmogCollection.PlayerHasTransmogByItemInfo) then
		return nil
	end
	local ok, has = pcall(C_TransmogCollection.PlayerHasTransmogByItemInfo, link)
	if not ok then return nil end
	if has then return "collected" end
	if C_TransmogCollection.GetItemInfo and C_TransmogCollection.PlayerCanCollectSource then
		local ok2, _, sourceID = pcall(C_TransmogCollection.GetItemInfo, link)
		if ok2 and sourceID then
			local ok3, hasData, canCollect = pcall(C_TransmogCollection.PlayerCanCollectSource, sourceID)
			if ok3 and hasData ~= nil then
				return canCollect and "learnable" or "notforclass"
			end
		end
	end
	return "uncollected"
end

-- ---------------------------------------------------------------------------
-- Classification
-- ---------------------------------------------------------------------------

-- Returns verdict, reason
local function Classify(e)
	local db = BT.db

	if db.keepList[e.itemID] or BUILTIN_KEEP[e.itemID] then
		return "KEEP", "on your keep list"
	end

	-- Caged battle pet or pet-class item: always tradable/collectible
	if e.isBattlePet or e.classID == CLASS_BATTLEPET
		or (e.classID == CLASS_MISC and e.subclassID == MISC_SUB_PET) then
		return "KEEP", "battle pet - cage/learn or sell on AH"
	end

	if e.classID == CLASS_WOWTOKEN then
		return "KEEP", "WoW Token"
	end

	if e.quality == HEIRLOOM then
		return "KEEP", "heirloom"
	end

	-- Sentimental / irreplaceable: old legendaries and artifact-quality items
	-- (Shadowlands legendaries, legion artifacts, quest-line mementos...) are
	-- usually impossible to reacquire once deleted.
	if (e.quality == LEGENDARY or e.quality == ARTIFACT) and isOldXpac(e.expacID) then
		return "BANK", ("old %s-era legendary/artifact - cannot be reacquired; warband-bank it, never delete"):format(xpacName(e.expacID))
	end

	-- Quest-bound rewards from old expansions: if the quest line was removed
	-- or is unrepeatable, a deleted copy is gone for good. Actual quest items
	-- (classID 12) are excluded - those are leftovers, handled below.
	if (e.bindType or 0) == 4 and isOldXpac(e.expacID) and e.classID ~= CLASS_QUEST then
		return "BANK", ("quest-bound reward from %s - may be impossible to reobtain; bank if it means something to you"):format(xpacName(e.expacID))
	end

	-- Unopened containers: open before judging the container
	if e.hasLoot then
		return "REVIEW", "openable container - open it before deciding"
	end

	-- Quest items
	local q = e.questInfo
	if q and (q.isQuestItem or q.questID) then
		if q.questID and not q.isActive then
			return "REVIEW", "starts a quest you have not accepted - right-click it first"
		end
		if q.isActive then
			return "KEEP", "tied to a quest currently in your log"
		end
		return "REVIEW", "quest item, no matching quest in your log - useless without the quest; delete is normally safe"
	end
	if e.classID == CLASS_QUEST then
		return "REVIEW", "quest item, no matching quest in your log - useless without the quest; delete is normally safe"
	end

	-- Grey junk
	if e.quality == POOR then
		if e.noValue then
			return "DELETE", "grey junk with no vendor value"
		end
		return "SELL", "grey junk"
	end

	-- Conjured items expire on logout anyway
	if ITEM_CONJURED and TooltipHas(e.tooltip, ITEM_CONJURED) then
		return "DELETE", "conjured item - expires on its own"
	end

	-- Toys / mounts / recipes you already know
	local alreadyKnown = ITEM_SPELL_KNOWN and TooltipHas(e.tooltip, ITEM_SPELL_KNOWN)
	if PlayerHasToy and C_ToyBox and C_ToyBox.GetToyInfo and C_ToyBox.GetToyInfo(e.itemID) then
		if PlayerHasToy(e.itemID) then
			if e.noValue or (e.sellPrice or 0) == 0 then
				return "DELETE", "toy already in your Toy Box, no vendor value"
			end
			return "SELL", "toy already in your Toy Box"
		end
		return "KEEP", "toy not yet learned - use it"
	end
	if alreadyKnown then
		if e.noValue or (e.sellPrice or 0) == 0 then
			return "DELETE", "already known (recipe/mount/etc), no vendor value"
		end
		return "SELL", "already known (recipe/mount/etc)"
	end

	-- Account-bound: safe to park on an alt or in the warband bank
	if ACCOUNT_BINDS[e.bindType or 0] then
		return "KEEP", "account-bound (warbound) - usable across your warband"
	end

	-- Equipment
	if e.classID == 2 or e.classID == 4 then -- Weapon / Armor
		-- Tabards and shirts are pure cosmetics: item level is meaningless and
		-- many (rep, event, questline) are painful or impossible to reacquire.
		if e.equipLoc == "INVTYPE_TABARD" or e.equipLoc == "INVTYPE_BODY" then
			return "REVIEW", "cosmetic tabard/shirt - ignore its ilvl; many are hard to reacquire, so bank unless you know a vendor still sells it"
		end
		local realIlvl = e.detailedIlvl or e.itemLevel or 0
		if e.isBound then
			if isOldXpac(e.expacID) or (BT.equippedIlvl > 0 and realIlvl < BT.equippedIlvl * 0.85) then
				if NO_APPEARANCE_EQUIP[e.equipLoc or ""] then
					return "SELL", string.format("outdated jewelry/trinket (ilvl %d vs your %d) - no appearance to lose", realIlvl, BT.equippedIlvl)
				end
				local status = AppearanceStatus(e.link)
				if status == "collected" then
					return "SELL", string.format("outdated soulbound gear (ilvl %d vs your %d), appearance collected", realIlvl, BT.equippedIlvl)
				elseif status == "learnable" then
					return "REVIEW", string.format("outdated gear (ilvl %d) - EQUIP IT ONCE to learn its appearance, then sell", realIlvl)
				elseif status == "notforclass" then
					return "REVIEW", string.format("outdated gear (ilvl %d), appearance not collectible by this character (class/armor type) - bank for an alt or accept the loss", realIlvl)
				end
				return "REVIEW", string.format("outdated soulbound gear (ilvl %d vs your %d), appearance status unknown - check before selling", realIlvl, BT.equippedIlvl)
			end
			return "KEEP", "current-content gear"
		end
		if (e.bindType or 0) == 2 then -- BoE
			return "AH", string.format("unbound BoE gear (ilvl %d) - auction or wear", realIlvl)
		end
		return "REVIEW", "unbound gear"
	end

	-- Consumables. Stat consumables (potions/flasks/food) age out with their
	-- expansion, but generic/"Other" utility consumables (gliders, disguises,
	-- illusions, gadgets) usually keep working forever - never auto-sell those.
	if e.classID == CLASS_CONSUMABLE then
		if (e.subclassID == 0 or e.subclassID == 8) and isOldXpac(e.expacID) then
			return "REVIEW", ("utility/novelty consumable from %s (glider/disguise/gadget?) - many still work; test it before tossing"):format(xpacName(e.expacID))
		end
		if isPrevXpac(e.expacID) then
			return "REVIEW", ("last-expansion consumable (%s) - may still help while leveling"):format(xpacName(e.expacID))
		end
		if isOldXpac(e.expacID) then
			if e.noValue or (e.sellPrice or 0) == 0 then
				return "DELETE", ("expired consumable from %s, no vendor value"):format(xpacName(e.expacID))
			end
			return "SELL", ("expired consumable from %s"):format(xpacName(e.expacID))
		end
		return "KEEP", "current-expansion consumable"
	end

	-- Crafting materials
	if e.classID == CLASS_TRADEGOODS or e.classID == CLASS_REAGENT
		or e.classID == CLASS_GEM or e.classID == CLASS_ENHANCE or e.isCraftingReagent then
		if isOldXpac(e.expacID) then
			if e.isBound or ACCOUNT_BINDS[e.bindType or 0] then
				return "REVIEW", ("old BOUND crafting material (%s) - cannot be auctioned; vendor it or keep for legacy crafting"):format(xpacName(e.expacID))
			end
			return "AH", ("old crafting material (%s) - no current use; old mats often sell on the AH, otherwise vendor"):format(xpacName(e.expacID))
		end
		return "KEEP", "current crafting material"
	end

	-- Recipes not yet known (known ones were caught above)
	if e.classID == CLASS_RECIPE then
		if isOldXpac(e.expacID) then
			return "AH", "unlearned old recipe - learn it, or list on AH"
		end
		return "KEEP", "unlearned current recipe"
	end

	if e.classID == CLASS_GLYPH then
		return "REVIEW", "glyph (mostly a retired system) - vendor unless you want the cosmetic effect"
	end

	if e.classID == CLASS_PROFESSION then
		return "KEEP", "profession equipment"
	end

	if e.classID == CLASS_MISC then
		if e.subclassID == MISC_SUB_HOLIDAY then
			return "REVIEW", "holiday/event item - comes back with the event; safe to toss, bank if you want it next year"
		end
		if e.subclassID == MISC_SUB_MOUNT then
			return "KEEP", "mount not yet learned - use it"
		end
		-- Unique old curios tend to be one-time acquisitions (event rewards,
		-- keepsakes) - once deleted they are usually gone. Requires an exact
		-- "Unique" tooltip line (not "Unique-Equipped"/"Unique (20)") and a
		-- single copy: a stack of 6 is not a keepsake.
		if isOldXpac(e.expacID) and (e.count or 1) == 1
			and ITEM_UNIQUE and TooltipHasExact(e.tooltip, ITEM_UNIQUE) then
			return "BANK", ("unique %s keepsake - likely one-time acquisition; bank rather than delete"):format(xpacName(e.expacID))
		end
		if isOldXpac(e.expacID) and (e.quality or 1) >= 2 then
			return "REVIEW", ("old %s item (token/teleport/curio?) - check tooltip; bank if irreplaceable, otherwise toss"):format(xpacName(e.expacID))
		end
	end

	-- Fallback: judge by expansion
	if isOldXpac(e.expacID) then
		return "REVIEW", ("item from %s with no current-content match"):format(xpacName(e.expacID))
	end
	return "KEEP", "current or expansion-agnostic item"
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

local function BuildEntry(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not info or not info.itemID then return nil end

	local e = {
		bag = bag, slot = slot,
		itemID = info.itemID,
		count = info.stackCount or 1,
		icon = info.iconFileID,
		link = info.hyperlink,
		quality = info.quality,
		isBound = info.isBound,
		noValue = info.hasNoValue,
		hasLoot = info.hasLoot,
		name = info.itemName,
	}

	if e.link and e.link:find("battlepet:", 1, true) then
		e.isBattlePet = true
		e.name = e.name or "Caged battle pet"
	else
		local name, link, quality, itemLevel, minLevel, _, _, _, equipLoc, tex,
			sellPrice, classID, subclassID, bindType, expacID, setID,
			isCraftingReagent = C_Item.GetItemInfo(e.link or e.itemID)
		e.name = name or e.name or ("item " .. e.itemID)
		e.link = link or e.link
		e.quality = quality or e.quality
		e.itemLevel = itemLevel
		e.minLevel = minLevel
		e.equipLoc = equipLoc
		e.icon = e.icon or tex
		e.sellPrice = sellPrice
		e.classID = classID
		e.subclassID = subclassID
		e.bindType = bindType
		e.expacID = expacID
		e.setID = setID
		e.isCraftingReagent = isCraftingReagent
		if C_Item.GetDetailedItemLevelInfo and e.link then
			local ok, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, e.link)
			if ok then e.detailedIlvl = ilvl end
		end
	end

	local okq, qinfo = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)
	e.questInfo = okq and qinfo or nil

	e.tooltip = GetTooltipLines(bag, slot)

	e.verdict, e.reason = Classify(e)
	e.tag = ReviewTag(e.reason)
	return e
end

-- Bank container IDs vary across bank reworks (legacy bank+bags, 11.2+
-- character tabs, warband/account tabs). Collect every candidate the client's
-- enum knows about; unavailable ones report 0 slots and scan as empty.
local function BankBags()
	local E = (Enum and Enum.BagIndex) or {}
	local seen, bags = {}, {}
	local function add(v)
		if type(v) == "number" and not seen[v] then
			seen[v] = true
			bags[#bags + 1] = v
		end
	end
	add(E.Bank or BANK_CONTAINER or -1)
	add(E.Reagentbank); add(E.ReagentBank); add(REAGENTBANK_CONTAINER)
	for i = 1, 7 do add(E["BankBag_" .. i]) end
	for i = 1, 6 do add(E["CharacterBankTab_" .. i]) end
	for i = 1, 5 do add(E["AccountBankTab_" .. i]) end
	return bags
end

local function GetScanBags(mode)
	if mode == "bank" then return BankBags() end
	local bags = {}
	for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5) do
		bags[#bags + 1] = bag
	end
	return bags
end

function BT:Scan(onDone)
	if InCombatLockdown() then
		chat("Cannot scan during combat (item data is restricted in 12.x combat lockdown).")
		return
	end
	self.scanMode = self.scanMode or "bags"
	if self.scanMode == "bank" and not self.bankOpen then
		chat("The bank is closed - bank contents are only readable while it is open. Showing bags instead.")
		self.scanMode = "bags"
	end

	wipe(self.results)
	local _, equipped = GetAverageItemLevel()
	self.equippedIlvl = math.floor(equipped or 0)

	local pending, loopDone = 0, false
	local function finishIfReady()
		if loopDone and pending == 0 then
			table.sort(self.results, function(a, b)
				if a.verdict ~= b.verdict then
					return VERDICT_ORDER[a.verdict] < VERDICT_ORDER[b.verdict]
				end
				if (a.tag or "") ~= (b.tag or "") then
					return (a.tag or "") < (b.tag or "")
				end
				if (a.name or "") ~= (b.name or "") then
					return (a.name or "") < (b.name or "")
				end
				return (a.bag * 100 + a.slot) < (b.bag * 100 + b.slot)
			end)
			if onDone then onDone() end
		end
	end

	for _, bag in ipairs(GetScanBags(self.scanMode)) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local probe = C_Container.GetContainerItemInfo(bag, slot)
			if probe and probe.itemID then
				pending = pending + 1
				local item = Item:CreateFromBagAndSlot(bag, slot)
				local function record()
					local entry = BuildEntry(bag, slot)
					if entry then self.results[#self.results + 1] = entry end
					pending = pending - 1
					finishIfReady()
				end
				if item:IsItemEmpty() then
					record()
				else
					item:ContinueOnItemLoad(record)
				end
			end
		end
	end
	loopDone = true
	finishIfReady()
end

function BT:Counts()
	local c = { SELL = 0, DELETE = 0, REVIEW = 0, BANK = 0, AH = 0, KEEP = 0, total = 0, sellValue = 0 }
	for _, e in ipairs(self.results) do
		c[e.verdict] = (c[e.verdict] or 0) + 1
		c.total = c.total + 1
		if e.verdict == "SELL" then
			c.sellValue = c.sellValue + (e.sellPrice or 0) * (e.count or 1)
		end
	end
	return c
end

-- ---------------------------------------------------------------------------
-- Actions: sell / delete / keep
-- ---------------------------------------------------------------------------

function BT:SellFlagged()
	if self.scanMode == "bank" then
		chat("Selling works on the bags scan only - the vendor and the bank cannot both be open.")
		return
	end
	if not self.merchantOpen then
		chat("Open a vendor first, then press the sell button.")
		return
	end
	local sold, value = 0, 0
	for _, e in ipairs(self.results) do
		if e.verdict == "SELL" and not e.noValue then
			local info = C_Container.GetContainerItemInfo(e.bag, e.slot)
			if info and info.itemID == e.itemID and not info.isLocked then
				C_Container.UseContainerItem(e.bag, e.slot)
				sold = sold + 1
				value = value + (e.sellPrice or 0) * (e.count or 1)
				if self.db.settings.sellBatch12 and sold >= 12 then break end
			end
		end
	end
	if sold == 0 then
		chat("Nothing flagged SELL is left in your bags.")
	else
		chat(string.format("Sold %d item(s) for %s.%s", sold,
			GetMoneyString and GetMoneyString(value) or (value .. "c"),
			self.db.settings.sellBatch12
				and " (Batches of 12 so everything stays buyback-able - press again for the next batch.)" or ""))
		C_Timer.After(0.7, function() BT:RefreshUI(true) end)
	end
end

function BT:DeleteEntry(e)
	local info = C_Container.GetContainerItemInfo(e.bag, e.slot)
	if not info or info.itemID ~= e.itemID then
		chat("That slot changed since the scan - rescanning instead.")
		self:RefreshUI(true)
		return
	end
	ClearCursor()
	C_Container.PickupContainerItem(e.bag, e.slot)
	if CursorHasItem() then
		DeleteCursorItem()
		chat("Deleted " .. (e.link or e.name) .. ".")
	end
	ClearCursor()
	C_Timer.After(0.5, function() BT:RefreshUI(true) end)
end

function BT:ToggleKeep(itemID)
	if self.db.keepList[itemID] then
		self.db.keepList[itemID] = nil
	else
		self.db.keepList[itemID] = true
	end
	self:RefreshUI(true)
end

StaticPopupDialogs["BAGPRAUDIT_CONFIRM_DELETE"] = {
	text = "BagPraudit: permanently delete %s?",
	button1 = DELETE,
	button2 = CANCEL,
	OnAccept = function(self, data) BT:DeleteEntry(data) end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Export (paste-able report)
-- ---------------------------------------------------------------------------

function BT:BuildExport()
	local lines = {}
	local playerName = UnitName("player") or "?"
	local realm = GetRealmName and GetRealmName() or "?"
	lines[#lines + 1] = string.format(
		"BagPraudit %s export | %s-%s | level %d | equipped ilvl %d | client %s | xpacLevel %d | scope %s | %s",
		VERSION, playerName, realm, UnitLevel("player") or 0, self.equippedIlvl or 0,
		(GetBuildInfo()), CUR_XPAC, self.scanMode or "bags", date("%Y-%m-%d %H:%M"))
	lines[#lines + 1] = "verdict | bag:slot | itemID | count | class/sub | xpac | ilvl | name | reason"
	for _, e in ipairs(self.results) do
		lines[#lines + 1] = string.format("%s | %d:%d | %d | %d | %s/%s | %s | %s | %s | %s",
			e.verdict, e.bag, e.slot, e.itemID, e.count or 1,
			tostring(e.classID), tostring(e.subclassID),
			tostring(e.expacID), tostring(e.detailedIlvl or e.itemLevel),
			e.name or "?", e.reason or "")
	end
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local ROW_HEIGHT = 22
local rowPool = {}

local function CreateMainFrame()
	local f = CreateFrame("Frame", "BagPrauditWindow", UIParent, "BackdropTemplate")
	f:SetSize(760, 540)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 8, right = 8, top = 8, bottom = 8 },
	})
	f:Hide()
	table.insert(UISpecialFrames, "BagPrauditWindow") -- Esc closes it

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -16)
	f.title:SetText("Bag Praudit")

	f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.summary:SetPoint("TOP", 0, -40)

	f.junk = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.junk:SetPoint("TOP", 0, -56)

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	f.scroll = CreateFrame("ScrollFrame", "BagPrauditScroll", f, "UIPanelScrollFrameTemplate")
	f.scroll:SetPoint("TOPLEFT", 14, -74)
	f.scroll:SetPoint("BOTTOMRIGHT", -34, 48)

	f.content = CreateFrame("Frame", nil, f.scroll)
	f.content:SetSize(700, 10)
	f.scroll:SetScrollChild(f.content)

	local rescan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	rescan:SetSize(90, 24)
	rescan:SetPoint("BOTTOMLEFT", 14, 14)
	rescan:SetText("Rescan")
	rescan:SetScript("OnClick", function() BT:RefreshUI(true) end)

	f.sellBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.sellBtn:SetSize(160, 24)
	f.sellBtn:SetPoint("LEFT", rescan, "RIGHT", 8, 0)
	f.sellBtn:SetText("Sell flagged (vendor)")
	f.sellBtn:SetScript("OnClick", function() BT:SellFlagged() end)

	local export = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	export:SetSize(90, 24)
	export:SetPoint("LEFT", f.sellBtn, "RIGHT", 8, 0)
	export:SetText("Export")
	export:SetScript("OnClick", function() BT:ShowExport() end)

	local showKeep = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
	showKeep:SetSize(24, 24)
	showKeep:SetPoint("LEFT", export, "RIGHT", 12, 0)
	showKeep.text = showKeep:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	showKeep.text:SetPoint("LEFT", showKeep, "RIGHT", 2, 0)
	showKeep.text:SetText("Show KEEP items")
	showKeep:SetScript("OnClick", function(btn)
		BT.db.settings.showKeep = btn:GetChecked() and true or false
		BT:RefreshUI(false)
	end)
	f.showKeep = showKeep

	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.hint:SetPoint("BOTTOMRIGHT", -16, 18)
	f.hint:SetText("click header to collapse  |  X = delete (confirm)  |  hover row for tooltip")

	return f
end

local function AcquireRow(index, parent)
	local row = rowPool[index]
	if row then return row end

	row = CreateFrame("Button", nil, parent)
	row:SetSize(690, ROW_HEIGHT)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("LEFT", 2, 0)

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.text:SetWidth(280)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)

	row.reason = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.reason:SetPoint("LEFT", row.text, "RIGHT", 6, 0)
	row.reason:SetPoint("RIGHT", row, "RIGHT", -80, 0)
	row.reason:SetJustifyH("LEFT")
	row.reason:SetWordWrap(false)

	row.keepBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.keepBtn:SetSize(44, 18)
	row.keepBtn:SetPoint("RIGHT", -30, 0)
	row.keepBtn:SetScript("OnClick", function(btn) BT:ToggleKeep(btn.itemID) end)

	row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.delBtn:SetSize(22, 18)
	row.delBtn:SetPoint("RIGHT", -4, 0)
	row.delBtn:SetText("X")
	row.delBtn:SetScript("OnClick", function(btn)
		local dialog = StaticPopup_Show("BAGPRAUDIT_CONFIRM_DELETE",
			btn.entry.link or btn.entry.name or "item")
		if dialog then dialog.data = btn.entry end
	end)

	row:SetScript("OnEnter", function(self)
		if self.entry then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetBagItem(self.entry.bag, self.entry.slot)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("|cff6699ffBag Praudit:|r " .. (self.entry.reason or ""), 1, 0.82, 0, true)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row:SetScript("OnClick", function(self)
		if self.entry and self.entry.link and IsModifiedClick("CHATLINK") then
			ChatEdit_InsertLink(self.entry.link)
		end
	end)

	rowPool[index] = row
	return row
end

local headerPool = {}
local function AcquireHeader(index, parent)
	local h = headerPool[index]
	if h then return h end
	h = CreateFrame("Button", nil, parent)
	h:SetSize(690, 20)
	h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	h.label = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	h.label:SetPoint("LEFT", 2, 0)
	h.label:SetJustifyH("LEFT")
	h:SetScript("OnClick", function(btn)
		local cset = BT.db.settings.collapsed
		cset[btn.verdict] = not cset[btn.verdict] or nil
		BT:RenderList()
	end)
	headerPool[index] = h
	return h
end

local subheaderPool = {}
local function AcquireSubheader(index, parent)
	local s = subheaderPool[index]
	if s then return s end
	s = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	s:SetJustifyH("LEFT")
	s:SetTextColor(0.75, 0.75, 0.75)
	subheaderPool[index] = s
	return s
end

function BT:RenderList()
	local f = self.ui
	for _, r in ipairs(rowPool) do r:Hide() end
	for _, h in ipairs(headerPool) do h:Hide() end
	for _, s in ipairs(subheaderPool) do s:Hide() end

	local c = self:Counts()
	local collapsed = self.db.settings.collapsed
	local y = -4
	local rowIdx, headerIdx, subIdx = 0, 0, 0
	local lastVerdict, lastTag

	for _, e in ipairs(self.results) do
		local show = e.verdict ~= "KEEP" or self.db.settings.showKeep
		if show then
			if e.verdict ~= lastVerdict then
				lastVerdict = e.verdict
				lastTag = nil
				headerIdx = headerIdx + 1
				local h = AcquireHeader(headerIdx, f.content)
				h:SetPoint("TOPLEFT", 4, y - 4)
				h.verdict = e.verdict
				h.label:SetText(string.format("|c%s[%s] %s (%d)|r",
					VERDICT_COLOR[e.verdict], collapsed[e.verdict] and "+" or "-",
					VERDICT_LABEL[e.verdict], c[e.verdict] or 0))
				h:Show()
				y = y - 24
			end
			if not collapsed[e.verdict] then
				if e.verdict == "REVIEW" and e.tag ~= lastTag then
					lastTag = e.tag
					subIdx = subIdx + 1
					local s = AcquireSubheader(subIdx, f.content)
					s:SetPoint("TOPLEFT", 16, y - 3)
					s:SetText(e.tag or "Other")
					s:Show()
					y = y - 18
				end
				rowIdx = rowIdx + 1
				local row = AcquireRow(rowIdx, f.content)
				row:SetPoint("TOPLEFT", 4, y)
				row.entry = e
				row.icon:SetTexture(e.icon or 134400)
				local countStr = (e.count or 1) > 1 and (" x" .. e.count) or ""
				row.text:SetText((e.link or e.name or "?") .. countStr)
				row.reason:SetText(e.reason or "")
				row.keepBtn.itemID = e.itemID
				row.keepBtn:SetText(self.db.keepList[e.itemID] and "Unkeep" or "Keep")
				row.delBtn.entry = e
				if e.verdict == "DELETE" or e.verdict == "REVIEW" then
					row.delBtn:Show()
				else
					row.delBtn:Hide()
				end
				row:Show()
				y = y - ROW_HEIGHT
			end
		end
	end

	f.content:SetHeight(-y + 10)

	f.title:SetText(self.scanMode == "bank" and "Bag Praudit - Bank" or "Bag Praudit")

	local flagged = c.SELL + c.DELETE + c.REVIEW + c.AH
	local pct = c.total > 0 and math.floor(flagged / c.total * 100 + 0.5) or 0
	f.junk:SetText(string.format(
		"Junk score: |cffffd100%d%%|r  -  %d slot(s) freeable now, %d to review, %d for the AH",
		pct, c.SELL + c.DELETE, c.REVIEW, c.AH))

	f.summary:SetText(string.format(
		"%d items scanned  |  |c%sSELL %d|r (worth %s)  |c%sDELETE %d|r  |c%sREVIEW %d|r  |c%sBANK %d|r  |c%sAH %d|r  |c%sKEEP %d|r",
		c.total,
		VERDICT_COLOR.SELL, c.SELL, GetMoneyString and GetMoneyString(c.sellValue) or (c.sellValue .. "c"),
		VERDICT_COLOR.DELETE, c.DELETE,
		VERDICT_COLOR.REVIEW, c.REVIEW,
		VERDICT_COLOR.BANK, c.BANK,
		VERDICT_COLOR.AH, c.AH,
		VERDICT_COLOR.KEEP, c.KEEP))

	f.showKeep:SetChecked(self.db.settings.showKeep)
	if self.scanMode == "bank" then
		f.sellBtn:SetEnabled(false)
		f.sellBtn:SetText("Sell (bags mode only)")
	else
		f.sellBtn:SetEnabled(self.merchantOpen and c.SELL > 0)
		f.sellBtn:SetText(self.merchantOpen and "Sell flagged" or "Sell flagged (need vendor)")
	end
end

function BT:RefreshUI(rescan, mode)
	if mode then self.scanMode = mode end
	self.scanMode = self.scanMode or "bags"
	if not self.ui then self.ui = CreateMainFrame() end
	self.ui:Show()
	if rescan or #self.results == 0 then
		self:Scan(function() BT:RenderList() end)
	else
		self:RenderList()
	end
end

function BT:ShowExport()
	if not self.exportFrame then
		local f = CreateFrame("Frame", "BagPrauditExport", UIParent, "BackdropTemplate")
		f:SetSize(620, 420)
		f:SetPoint("CENTER", 40, -20)
		f:SetFrameStrata("DIALOG")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		f:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 8, right = 8, top = 8, bottom = 8 },
		})
		table.insert(UISpecialFrames, "BagPrauditExport")

		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -14)
		title:SetText("BagPraudit export - Ctrl+A then Ctrl+C to copy")

		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -6, -6)

		local scroll = CreateFrame("ScrollFrame", "BagPrauditExportScroll", f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 14, -36)
		scroll:SetPoint("BOTTOMRIGHT", -34, 14)

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetFontObject(ChatFontSmall)
		edit:SetWidth(560)
		edit:SetAutoFocus(false)
		edit:SetScript("OnEscapePressed", function(box) box:ClearFocus() f:Hide() end)
		scroll:SetScrollChild(edit)
		f.edit = edit
		self.exportFrame = f
	end
	self.exportFrame.edit:SetText(self:BuildExport())
	self.exportFrame:Show()
	self.exportFrame.edit:SetFocus()
	self.exportFrame.edit:HighlightText()
end

-- ---------------------------------------------------------------------------
-- Events, slash commands, addon compartment
-- ---------------------------------------------------------------------------

BT:RegisterEvent("PLAYER_LOGIN")
BT:RegisterEvent("MERCHANT_SHOW")
BT:RegisterEvent("MERCHANT_CLOSED")
BT:RegisterEvent("BAG_UPDATE_DELAYED")
BT:RegisterEvent("BANKFRAME_OPENED")
BT:RegisterEvent("BANKFRAME_CLOSED")

BT:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_LOGIN" then
		InitDB()
		chat("loaded. /praudit (or /bpr) to audit your bags.")
	elseif event == "MERCHANT_SHOW" then
		self.merchantOpen = true
		if self.ui and self.ui:IsShown() then self:RenderList() end
	elseif event == "MERCHANT_CLOSED" then
		self.merchantOpen = false
		if self.ui and self.ui:IsShown() then self:RenderList() end
	elseif event == "BANKFRAME_OPENED" then
		self.bankOpen = true
		if not self.bankHintDone then
			self.bankHintDone = true
			chat("Bank open - /praudit bank to audit your bank and warband tabs.")
		end
	elseif event == "BANKFRAME_CLOSED" then
		self.bankOpen = false
		if self.scanMode == "bank" then
			self.scanMode = "bags"
			if self.ui and self.ui:IsShown() then
				chat("Bank closed - switching back to the bags scan.")
				self:Scan(function() BT:RenderList() end)
			end
		end
	elseif event == "BAG_UPDATE_DELAYED" then
		if self.ui and self.ui:IsShown() and not self.rescanQueued then
			self.rescanQueued = true
			C_Timer.After(1.0, function()
				self.rescanQueued = false
				if self.ui:IsShown() and not InCombatLockdown() then
					self:Scan(function() BT:RenderList() end)
				end
			end)
		end
	end
end)

SLASH_BAGPRAUDIT1 = "/praudit"
SLASH_BAGPRAUDIT2 = "/bagpraudit"
SLASH_BAGPRAUDIT3 = "/bpr"
SlashCmdList.BAGPRAUDIT = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "bank" then
		if not (BT.bankOpen or (BankFrame and BankFrame:IsShown())) then
			chat("Open your bank first, then run /praudit bank.")
			return
		end
		BT.bankOpen = true
		BT:RefreshUI(true, "bank")
	elseif msg == "export" then
		if #BT.results == 0 then
			BT:Scan(function() BT:ShowExport() end)
		else
			BT:ShowExport()
		end
	elseif msg == "reset" then
		wipe(BT.db.keepList)
		chat("Keep list cleared.")
		BT:RefreshUI(true)
	elseif msg == "batch" then
		BT.db.settings.sellBatch12 = not BT.db.settings.sellBatch12
		chat("Sell in buyback-safe batches of 12: " .. tostring(BT.db.settings.sellBatch12))
	elseif msg == "help" then
		chat("/praudit - open the audit window (scans your bags)")
		chat("/praudit bank - audit your bank + warband tabs (bank must be open)")
		chat("/praudit export - copyable text report of the last scan")
		chat("/praudit reset - clear your keep list")
		chat("/praudit batch - toggle selling in batches of 12 (buyback safety)")
	else
		if BT.ui and BT.ui:IsShown() then
			BT.ui:Hide()
		else
			BT:RefreshUI(true, "bags")
		end
	end
end

function BagPraudit_OnCompartmentClick()
	SlashCmdList.BAGPRAUDIT("")
end
