-- Do not load anything here if electric is disabled
if not Config.Electric.enabled then
    return
end

local electricChargers = {}

-----------------------------------------------------------------------------------------------------------------------------------------
-- Threads
-----------------------------------------------------------------------------------------------------------------------------------------

-- Create sphere zones for each station, hooking up onEnter/onExit
function createElectricZones()
    assert(Utils.Zones, "You are using an outdated version of lc_utils. Please update your 'lc_utils' script to the latest version: https://github.com/LeonardoSoares98/lc_utils/releases/latest/download/lc_utils.zip")

    local stations = groupChargersByStation()

    for _, station in pairs(stations) do
        Utils.Zones.createZone({
            coords = station.center,
            radius = 50.0,
            onEnter = function()
                for _, charger in pairs(station.chargers) do
                    loadElectricCharger(charger)
                end
            end,
            onExit = function()
                for _, charger in pairs(station.chargers) do
                    unloadElectricCharger(charger)
                end
            end
        })
    end
end

function setupElectricTargets()
    local pumpModels = {}
    local seenModels = {}

    for _, chargerData in pairs(Config.Electric.chargersLocation) do
        local model = chargerData.prop
        if not seenModels[model] then
            seenModels[model] = true
            table.insert(pumpModels, model)
        end
    end

    for _, model in ipairs(pumpModels) do
        exports.ox_target:addModel(model, {
            {
                label = Utils.translate('target.open_recharge'),
                icon = 'fas fa-plug',
                iconColor = '#00a413',
                distance = 2.0,
                canInteract = function(entity)
                    return not mainUiOpen and not DoesEntityExist(fuelNozzle)
                end,
                onSelect = function(data)
                    local ped = PlayerPedId()
                    local playerCoords = GetEntityCoords(ped)
                    local pump, pumpModel = GetClosestPump(playerCoords, true)
                    if pump then
                        clientOpenUI(pump, pumpModel, true)
                    else
                        exports['lc_utils']:notify("error", Utils.translate("pump_not_found"))
                    end
                end
            },
            {
                label = Utils.translate('target.return_nozzle'),
                icon = 'fas fa-plug',
                iconColor = '#a42100',
                distance = 2.0,
                canInteract = function(entity)
                    return DoesEntityExist(fuelNozzle)
                end,
                onSelect = function(data)
                    returnNozzle()
                end
            }
        })
    end
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Utils
-----------------------------------------------------------------------------------------------------------------------------------------

function loadElectricCharger(chargerData)
    if not electricChargers[chargerData.location] then
        RequestModel(chargerData.prop)
        while not HasModelLoaded(chargerData.prop) do
            Wait(10)
        end

        local heading = chargerData.location.w + 180.0
        local electricCharger = CreateObject(chargerData.prop, chargerData.location.x, chargerData.location.y, chargerData.location.z, false, true, true)
        SetEntityHeading(electricCharger, heading)
        FreezeEntityPosition(electricCharger, true)

        electricChargers[chargerData.location] = electricCharger
    end
end

function unloadElectricCharger(chargerData)
    local charger = electricChargers[chargerData.location]
    if charger and DoesEntityExist(charger) then
        DeleteEntity(charger)
        electricChargers[chargerData.location] = nil
    end
end

-- Utility to group chargers by their station
function groupChargersByStation()
    local stations = {}
    for _, charger in pairs(Config.Electric.chargersLocation) do
        local assigned = false
        for _, station in pairs(stations) do
            local dist = #(station.center - vector3(charger.location.x, charger.location.y, charger.location.z))
            if dist < 20.0 then
                table.insert(station.chargers, charger)
                station.center = (station.center + vector3(charger.location.x, charger.location.y, charger.location.z)) / 2
                assigned = true
                break
            end
        end
        if not assigned then
            table.insert(stations, {
                center = vector3(charger.location.x, charger.location.y, charger.location.z),
                chargers = { charger }
            })
        end
    end
    return stations
end

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    deleteAllElectricChargers()
end)

function deleteAllElectricChargers()
    for _, charger in pairs(electricChargers) do
        if DoesEntityExist(charger) then
            DeleteEntity(charger)
        end
    end
    electricChargers = {}
end