import Foundation
import Observation

@MainActor @Observable
final class AlwaysOnRuntimeCoordinator {
    static let shared = AlwaysOnRuntimeCoordinator()
    let engine=AlwaysOnRuntimeEngine.shared;let worker=AlwaysOnWorkerMonitor.shared
    private(set) var lastError:String?;private(set) var configured=false;private var reconciliationTask:Task<Void,Never>?
    func configure(appState:TRAVISAppState){
        guard !configured else{return};configured=true;worker.start()
        // Reconcile anything the LaunchAgent completed while the GUI was closed.
        _=HeadlessMissionReconciler.reconcile(runtime:appState.taskRuntime)
        reconciliationTask=Task{[weak appState] in while !Task.isCancelled{if let appState{_ = HeadlessMissionReconciler.reconcile(runtime:appState.taskRuntime)};try? await Task.sleep(for:.seconds(2))}}
        engine.onDueJob={ [weak appState] job in guard let appState else{throw CoordinatorError.appUnavailable};guard AlwaysOnWorkerMonitor.shared.snapshot?.killSwitch != true else{throw CoordinatorError.killSwitch};switch job.kind{case .mission:await MainActor.run{appState.runAutonomousMissionV2(goal:job.payload)};case .watcher:await MainActor.run{appState.chatInput=job.payload;appState.sendChat()};case .tradingPaper,.tradingTestnet:await MainActor.run{appState.chatInput=job.payload;appState.sendChat()}}}
        Task{[weak self] in let stored=await AlwaysOnJobStore.shared.load();let recovered=AlwaysOnRecoveryPolicy.recover(stored);for job in recovered{self?.engine.schedule(job)};self?.engine.start()}
    }
    func emergencyStop(){do{try worker.setKillSwitch(true);for job in engine.jobs where job.isEnabled{engine.pause(job.id)};lastError=nil}catch{lastError=error.localizedDescription}}
    func clearEmergencyStop(){do{try worker.setKillSwitch(false);lastError=nil}catch{lastError=error.localizedDescription}}
}
enum CoordinatorError:LocalizedError {case appUnavailable,killSwitch;var errorDescription:String?{switch self{case .appUnavailable:return "TRAVIS application runtime unavailable";case .killSwitch:return "TRAVIS emergency kill switch is active"}}}
