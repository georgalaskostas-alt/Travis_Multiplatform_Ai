import Foundation
struct TravisBridgeAlwaysOnJobSnapshot: Codable, Equatable, Identifiable { var id:UUID;var title:String;var kind:String;var state:String;var nextRunAt:Date?;var consecutiveFailures:Int;var lastError:String?;var isEnabled:Bool }
struct TravisBridgeAlwaysOnSnapshot: Codable, Equatable { var workerHealthy:Bool;var workerPID:Int32?;var killSwitchEnabled:Bool;var jobsTotal:Int;var jobsActive:Int;var jobsFailed:Int;var summary:String;var jobs:[TravisBridgeAlwaysOnJobSnapshot] }
