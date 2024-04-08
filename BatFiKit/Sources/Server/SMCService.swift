//
//  SMCService.swift
//
//
//  Created by Adam Różyński on 29/03/2024.
//

import Foundation
import os
import Sentry
import Shared

actor SMCService {
    private lazy var logger = Logger(subsystem: Constant.helperBundleIdentifier, category: "SMC Service")
    private var smcIsOpened = false

    init() {
        Task {
            await openSMCIfNeeded()
        }
    }

    func close() {
        SMCKit.close()
    }

    func setChargingMode(_ message: SMCChargingCommand) async throws {
        openSMCIfNeeded()
        let disableChargingByte: UInt8
        let inhibitChargingByte: UInt8
        let enableSystemChargeLimitByte: UInt8

        switch message {
        case .forceDischarging:
            disableChargingByte = 1
            inhibitChargingByte = 0
            enableSystemChargeLimitByte = 0
            logger.notice("Handling force discharge")
        case .auto:
            disableChargingByte = 0
            inhibitChargingByte = 0
            enableSystemChargeLimitByte = 0
            logger.notice("Handling enable charge")
        case .inhibitCharging:
            disableChargingByte = 0
            inhibitChargingByte = 02
            enableSystemChargeLimitByte = 0
            logger.notice("Handling inhibit charging")
        case .enableSystemChargeLimit:
            disableChargingByte = 0
            inhibitChargingByte = 0
            enableSystemChargeLimitByte = 1
            logger.notice("Handling enable system charge limit")
        }

        do {
            try SMCKit.writeData(.disableCharging, uint8: disableChargingByte)
            try SMCKit.writeData(.inhibitChargingC, uint8: inhibitChargingByte)
            try SMCKit.writeData(.inhibitChargingB, uint8: inhibitChargingByte)
            try SMCKit.writeData(.enableSystemChargeLimit, uint8: enableSystemChargeLimitByte)
        } catch {
            logger.critical("SMC writing error: \(error)")
            SentrySDK.capture(error: error)
            resetIfPossible()
            throw error
        }
    }

    func resetIfPossible() {
        do {
            try SMCKit.writeData(.disableCharging, uint8: 0)
            try SMCKit.writeData(.inhibitChargingC, uint8: 0)
            try SMCKit.writeData(.inhibitChargingB, uint8: 0)
            try SMCKit.writeData(.enableSystemChargeLimit, uint8: 0)
        } catch {
            logger.critical("Resetting charging state failed. \(error)")
            SentrySDK.capture(error: error)
        }
    }

    func smcChargingStatus() async throws -> SMCChargingStatus {
        openSMCIfNeeded()
        let forceDischarging = try SMCKit.readData(SMCKey.disableCharging)
        let inhibitChargingC = try SMCKit.readData(SMCKey.inhibitChargingC)
        let inhibitChargingB = try SMCKit.readData(SMCKey.inhibitChargingB)
        let lidClosed = try SMCKit.readData(SMCKey.lidClosed)

        logger.notice("Checking SMC status")

        return SMCChargingStatus(
            forceDischarging: forceDischarging.0 == 01,
            inhitbitCharging: (inhibitChargingC.0 == 02 && inhibitChargingB.0 == 02)
                || (inhibitChargingC.0 == 03 && inhibitChargingB.0 == 03),
            lidClosed: lidClosed.0 == 01
        )
    }

    func magsafeLEDColor(_ option: MagSafeLEDOption) async throws -> MagSafeLEDOption {
        openSMCIfNeeded()
        try SMCKit.writeData(SMCKey.magSafeLED, uint8: option.rawValue)
        do {
            let data = try SMCKit.readData(.magSafeLED)
            guard let option = MagSafeLEDOption(rawValue: data.0) else {
                throw SMCError.canNotCreateMagSafeLEDOption
            }
            return option
        } catch {
            SentrySDK.capture(error: error)
            throw error
        }

    }

    func getPowerDistribution() async throws -> PowerDistributionInfo {
        openSMCIfNeeded()
        let rawBatteryPower = try SMCKit.readData(SMCKey.batteryPower)
        let rawExternalPower = try SMCKit.readData(SMCKey.externalPower)

        var batteryPower = Float(fromBytes: (rawBatteryPower.0, rawBatteryPower.1, rawBatteryPower.2, rawBatteryPower.3))
        var externalPower = Float(fromBytes: (rawExternalPower.0, rawExternalPower.1, rawExternalPower.2, rawExternalPower.3))

        if abs(batteryPower) < 0.01 {
            batteryPower = 0
        }
        if externalPower < 0.01 {
            externalPower = 0
        }

        let systemPower = batteryPower + externalPower

        return PowerDistributionInfo(batteryPower: batteryPower, externalPower: externalPower, systemPower: systemPower)
    }

    private func openSMCIfNeeded() {
        if !smcIsOpened {
            do {
                try SMCKit.open()
                smcIsOpened = true
            } catch {
                SentrySDK.capture(error: error)
            }
        }
    }

}
