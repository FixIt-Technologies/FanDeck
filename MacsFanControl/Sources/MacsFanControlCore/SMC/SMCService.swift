//
//  SMCService.swift
//  MacsFanControlCore
//
//  Protocol for talking to the System Management Controller.
//  The real implementation needs IOKit AppleSMC; bootstrap ships a mock.
//

import Foundation

public protocol SMCService: AnyObject {
    var backendName: String { get }
    var isSimulated: Bool { get }
    func snapshot() -> (fans: [Fan], sensors: [TempSensor])
    func refresh()
    func setMode(_ mode: FanMode, for fanID: String)
}
