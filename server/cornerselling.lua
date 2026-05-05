--[[
    PATCH: qbx_drugs/server/cornerselling.lua
    ─────────────────────────────────────────
    EXPLOIT 1: sellCornerDrugs accepted `price` from the client.
               A modded menu could send price = 999999 and get paid that amount.

    EXPLOIT 2: giveStealItems accepted `amount` from the client with no cap.
               A modded client could send amount = 10000 and receive 10,000 drug items.

    FIX 1: We now store the server-generated offer per player in `pendingOffers`.
            When sellCornerDrugs fires, we use the stored price — the client's
            price parameter is ignored entirely.

    FIX 2: amount in giveStealItems is capped to a max of 15 (the same cap
            getDrugOffer already uses for the offer amount).

    HOW TO APPLY: Replace the full contents of server/cornerselling.lua with this file.
]]

local config = require 'config.server'

-- Stores the server-calculated offer per player so the client can never tamper with it.
-- Key: source (player server ID)
-- Value: { item, amount, price, expiresAt }
local pendingOffers = {}

-- Offer TTL: if a player gets an offer but doesn't complete the sale within 5 minutes,
-- the offer is discarded. This prevents offers accumulating forever.
local OFFER_TTL = 300

local function getAvailableDrugs(source)
    local availableDrugs = {}
    local player = exports.qbx_core:GetPlayer(source)

    if not player then return nil end

    for i = 1, #config.cornerSellingDrugsList do
        local itemName = config.cornerSellingDrugsList[i]
        local itemCount = exports.ox_inventory:Search(source, 'count', itemName)
        if itemCount > 0 then
            availableDrugs[#availableDrugs + 1] = {
                item   = itemName,
                amount = itemCount,
                label  = exports.ox_inventory:Items()[itemName].label,
            }
        end
    end
    return table.type(availableDrugs) ~= 'empty' and availableDrugs or nil
end

-- Periodic sweep to remove expired offers (runs every 60 seconds)
CreateThread(function()
    while true do
        Wait(60000)
        local now = os.time()
        for src, offer in pairs(pendingOffers) do
            if now > offer.expiresAt then
                pendingOffers[src] = nil
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    pendingOffers[source] = nil
end)

-- ─── getDrugOffer ─────────────────────────────────────────────────────────────
-- Unchanged logic, but now we STORE the result server-side before returning it.

lib.callback.register('qb-drugs:server:getDrugOffer', function(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then return nil end

    local availableDrugs = getAvailableDrugs(player.PlayerData.source)
    if availableDrugs == nil then return nil end

    local randomDrug   = math.random(1, #availableDrugs)
    local chosenDrug   = availableDrugs[randomDrug]
    local offeredAmount = math.random(1, chosenDrug.amount > 15 and 15 or chosenDrug.amount)
    local priceRange   = config.cornerSellingDrugsPrice[chosenDrug.item]
    local basePrice    = math.random(priceRange.min, priceRange.max)
    local isScam       = config.scamChance >= math.random(1, 100)
    local totalPrice   = isScam
        and basePrice * offeredAmount
        or  math.random(3, 10) * offeredAmount

    -- Store server-side — client never needs to know the real price until it's paid
    pendingOffers[source] = {
        item      = chosenDrug.item,
        idx       = randomDrug,
        amount    = offeredAmount,
        price     = totalPrice,
        expiresAt = os.time() + OFFER_TTL,
    }

    return { chosen = chosenDrug, idx = randomDrug, amount = offeredAmount, total = totalPrice }
end)

-- ─── giveStealItems ───────────────────────────────────────────────────────────
-- FIX: Cap `amount` to 15. Client can't manufacture items by inflating this.

RegisterNetEvent('qb-drugs:server:giveStealItems', function(drugType, amount)
    local availableDrugs = getAvailableDrugs(source)
    local player         = exports.qbx_core:GetPlayer(source)

    if not availableDrugs or not player then return end
    if not availableDrugs[drugType] then return end  -- validate drugType index

    -- FIX: Hard cap — getDrugOffer already limits offers to 15 max
    amount = math.min(math.abs(math.floor(amount)), 15)
    if amount < 1 then return end

    exports.ox_inventory:AddItem(player.PlayerData.source, availableDrugs[drugType].item, amount)
end)

-- ─── sellCornerDrugs ──────────────────────────────────────────────────────────
-- FIX: `price` param is now IGNORED. We use the server-stored pendingOffer instead.

RegisterNetEvent('qb-drugs:server:sellCornerDrugs', function(drugType, amount)
    -- Note: old signature was (drugType, amount, price) — price is dropped
    local player         = exports.qbx_core:GetPlayer(source)
    local availableDrugs = getAvailableDrugs(player.PlayerData.source)

    if not availableDrugs or not player then return end
    if not availableDrugs[drugType] then return end

    -- Retrieve the server-stored offer for this player
    local offer = pendingOffers[source]
    if not offer then
        -- No stored offer — either it expired or client is firing without going through getDrugOffer
        exports.qbx_core:Notify(player.PlayerData.source, locale('error.no_offer'), 'error')
        return
    end

    -- Validate the offer matches what the client is claiming to sell
    -- (drugType index and amount must match what the server offered)
    if offer.idx ~= drugType or offer.amount ~= amount then
        warn(('qbx_drugs: sellCornerDrugs mismatch from %s — offered idx=%s amt=%s, got idx=%s amt=%s'):format(
            player.PlayerData.citizenid, offer.idx, offer.amount, drugType, amount))
        pendingOffers[source] = nil
        return
    end

    -- Clear the offer immediately (single-use)
    pendingOffers[source] = nil

    local item    = offer.item
    local price   = offer.price   -- ← server's value, not the client's

    local hasItem = player.Functions.GetItemByName(item)
    if hasItem and hasItem.amount >= amount then
        exports.qbx_core:Notify(player.PlayerData.source, locale('success.offer_accepted'), 'success')
        exports.ox_inventory:RemoveItem(player.PlayerData.source, item, amount)
        player.Functions.AddMoney('cash', price, 'sold-cornerdrugs')

        if config.policeCallChance >= math.random(1, 100) then
            TriggerEvent('police:server:policeAlert', locale('info.possible_drug_dealing'), nil, player.PlayerData.source)
        end
    else
        TriggerClientEvent('qb-drugs:client:cornerselling', player.PlayerData.source)
    end
end)

-- ─── robCornerDrugs ───────────────────────────────────────────────────────────
-- Unchanged, but cap amount for consistency

RegisterNetEvent('qb-drugs:server:robCornerDrugs', function(drugType, amount)
    local player         = exports.qbx_core:GetPlayer(source)
    local availableDrugs = getAvailableDrugs(player.PlayerData.source)

    if not availableDrugs or not player then return end
    if not availableDrugs[drugType] then return end

    amount = math.min(math.abs(math.floor(amount)), 15)
    if amount < 1 then return end

    exports.ox_inventory:RemoveItem(player.PlayerData.source, availableDrugs[drugType].item, amount)
end)
