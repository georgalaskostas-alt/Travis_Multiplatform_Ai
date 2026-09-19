import Foundation
import Observation

@MainActor @Observable
final class AlwaysOnRuntimeCoordinator {
    static let shared = AlwaysOnRuntimeCoordinator()
    let engine=AlwaysOnRuntimeEngine.shared;let worker=AlwaysOnWorkerMonitor.shared
    private(set) var lastError:String?;private(set) var configured=false;private var reconciliationTask:Task<Void,Never>?
    func configure(appState:TRAVISAppState){
        guard !configured else{return};configured=true;worker.start();worker.refresh()
        _=HeadlessMissionReconciler.reconcile(runtime:appState.taskRuntime)
        AlwaysOnIntelligenceBootstrap.provision(monitor:worker)
        reconciliationTask=Task{[weak appState,weak self] in
            var bootstrapAttempts=0
            while !Task.isCancelled {
                if let appState{_ = HeadlessMissionReconciler.reconcile(runtime:appState.taskRuntime)}
                if bootstrapAttempts<6 {self?.worker.refresh();AlwaysOnIntelligenceBootstrap.provision(monitor:self?.worker ?? .shared);bootstrapAttempts += 1}
                try? await Task.sleep(for:.seconds(2))
            }
        }
        engine.onDueJob={ [weak appState] job in guard let appState else{throw CoordinatorError.appUnavailable};guard AlwaysOnWorkerMonitor.shared.snapshot?.killSwitch != true else{throw CoordinatorError.killSwitch};switch job.kind{case .mission:await MainActor.run{appState.runAutonomousMissionV2(goal:job.payload)};case .watcher:await MainActor.run{appState.chatInput=job.payload;appState.sendChat()};case .tradingPaper,.tradingTestnet:await MainActor.run{appState.chatInput=job.payload;appState.sendChat()}}}
        Task{[weak self] in
            guard let self else{return}
            do{
                let stored=try await AlwaysOnJobStore.shared.load()
                let recovered=AlwaysOnRecoveryPolicy.recover(stored)

                // Recovery is a single durable transition. Persist the whole
                // recovered snapshot before execution starts, then seed the
                // engine from that exact snapshot. This avoids per-job async
                // upserts racing a second store load during startup.
                try await AlwaysOnJobStore.shared.save(recovered)
                self.engine.start(initialJobs:recovered)
                self.lastError=nil
            }catch{
                // Never start from an invented empty state when the persisted
                // job store exists but cannot be decoded/read.
                self.lastError="Always-On recovery blocked: \(error.localizedDescription)"
            }
        }
    }
    func emergencyStop(){do{try worker.setKillSwitch(true);for job in engine.jobs where job.isEnabled{engine.pause(job.id)};lastError=nil}catch{lastError=error.localizedDescription}}
    func clearEmergencyStop(){do{try worker.setKillSwitch(false);lastError=nil}catch{lastError=error.localizedDescription}}
}
enum CoordinatorError:LocalizedError {case appUnavailable,killSwitch;var errorDescription:String?{switch self{case .appUnavailable:return "TRAVIS application runtime unavailable";case .killSwitch:return "TRAVIS emergency kill switch is active"}}}
