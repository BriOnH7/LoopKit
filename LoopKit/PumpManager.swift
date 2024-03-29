//
//  PumpManager.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit


public enum PumpManagerResult<T> {
    case success(T)
    case failure(Error)
}

public protocol PumpManagerStatusObserver: class {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus)
}

public protocol PumpManagerDelegate: DeviceManagerDelegate, PumpManagerStatusObserver {
    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager)

    func pumpManagerShouldProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool

    /// Informs the delegate that the manager is deactivating and should be deleted
    func pumpManagerWillDeactivate(_ pumpManager: PumpManager)

    /// Triggered when pump model changes. With a more formalized setup flow (which requires a successful model fetch),
    /// this delegate method could go away.
    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool)

    /// Reports an error that should be surfaced to the user
    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError)

    func pumpManager(_ pumpManager: PumpManager, didReadPumpEvents events: [NewPumpEvent], completion: @escaping (_ error: Error?) -> Void)

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (_ result: PumpManagerResult<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void)

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval)

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager)

    func pumpManagerRecommendsLoop(_ pumpManager: PumpManager)

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date

    func startDateToFilterNewReservoirEvents(for manager: PumpManager) -> Date
}


public protocol PumpManager: DeviceManager {
    /// Rounds a basal rate in U/hr to a rate supported by this pump.
    ///
    /// - Parameters:
    ///   - unitsPerHour: A desired rate of delivery in Units/hr
    /// - Returns: a supported rate of delivery in Units/hr. The rate returned should not be larger than the passed in rate.
    func roundToSupportedBasalRate(unitsPerHour: Double) -> Double

    /// Rounds a bolus volume in U to a delivery amount supported by this pump.
    ///
    /// - Parameters:
    ///   - units: A desired rate of delivery in U
    /// - Returns: a supported bolus volume in U. The rate returned should not be larger than the passed in rate.
    func roundToSupportedBolusVolume(units: Double) -> Double

    // User selectable basal rates
    var supportedBasalRates: [Double] { get }

    // User selectable bolus volumes
    var supportedBolusVolumes: [Double] { get }

    var maximumBasalScheduleEntryCount: Int { get }

    var minimumBasalScheduleEntryDuration: TimeInterval { get }
    
    var pumpManagerDelegate: PumpManagerDelegate? { get set }

    var pumpRecordsBasalProfileStartEvents: Bool { get }

    var pumpReservoirCapacity: Double { get }
    
    var status: PumpManagerStatus { get }
    
    func addStatusObserver(_ observer: PumpManagerStatusObserver)
    
    func removeStatusObserver(_ observer: PumpManagerStatusObserver)
    
    /// If the pump data (reservoir/events) is out of date, it will be fetched, and if successful, trigger a loop
    func assertCurrentPumpData()

    /// Returns a dose estimator for the current bolus, if one is in progress
    func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter?

    /// Send a bolus command and handle the result
    ///
    /// - Parameters:
    ///   - units: The number of units to deliver
    ///   - startDate: The date the bolus command was originally set
    ///   - willRequest: A closure called just before the pump command is sent, if all preconditions are met
    ///   - completion: A closure called after the command is complete
    ///   - result: A DoseEntry or an error describing why the command failed
    func enactBolus(units: Double, at startDate: Date, willRequest: @escaping (_ dose: DoseEntry) -> Void, completion: @escaping (_ result: PumpManagerResult<DoseEntry>) -> Void)

    /// Cancels the current, in progress, bolus.
    ///
    /// - Parameters:
    ///   - completion: A closure called after the command is complete
    ///   - result: A DoseEntry containing the actual delivery amount of the canceled bolus, nil if canceled bolus information is not available, or an error describing why the command failed.
    func cancelBolus(completion: @escaping (_ result: PumpManagerResult<DoseEntry?>) -> Void)

    /// Send a temporary basal rate command and handle the result
    ///
    /// - Parameters:
    ///   - unitsPerHour: The temporary basal rate to set
    ///   - duration: The duration of the temporary basal rate.
    ///   - completion: A closure called after the command is complete
    ///   - result: A DoseEntry or an error describing why the command failed
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (_ result: PumpManagerResult<DoseEntry>) -> Void)

    func updateBLEHeartbeatPreference()
    
    func suspendDelivery(completion: @escaping (_ error: Error?) -> Void)
    
    func resumeDelivery(completion: @escaping (_ error: Error?) -> Void)
}
