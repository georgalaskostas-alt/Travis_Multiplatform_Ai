import Foundation
struct TravisBridgeAlwaysOnJobSnapshot: Codable, Equatable, Identifiable {
    var id:UUID;var title:String;var kind:String;var state:String;var nextRunAt:Date?;var consecutiveFailures:Int;var lastError:String?;var isEnabled:Bool;var lastCompletedAt:Date?;var lastSummary:String?;var finalReport:String?
    init(id:UUID,title:String,kind:String,state:String,nextRunAt:Date?,consecutiveFailures:Int,lastError:String?,isEnabled:Bool,lastCompletedAt:Date?=nil,lastSummary:String?=nil,finalReport:String?=nil){self.id=id;self.title=title;self.kind=kind;self.state=state;self.nextRunAt=nextRunAt;self.consecutiveFailures=consecutiveFailures;self.lastError=lastError;self.isEnabled=isEnabled;self.lastCompletedAt=lastCompletedAt;self.lastSummary=lastSummary;self.finalReport=finalReport}
}
struct TravisBridgeAlwaysOnSnapshot: Codable, Equatable { var workerHealthy:Bool;var workerPID:Int32?;var killSwitchEnabled:Bool;var jobsTotal:Int;var jobsActive:Int;var jobsFailed:Int;var summary:String;var jobs:[TravisBridgeAlwaysOnJobSnapshot] }
