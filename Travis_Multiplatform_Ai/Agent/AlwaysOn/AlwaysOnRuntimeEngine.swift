import Foundation
import Observation

@MainActor @Observable
final class AlwaysOnRuntimeEngine {
    static let shared = AlwaysOnRuntimeEngine()
    private(set) var jobs:[AlwaysOnJob]=[]
    private(set) var isRunning=false
    private(set) var startedAt:Date?
    private(set) var lastHeartbeat:Date?
    var onDueJob: ((AlwaysOnJob) async throws -> Void)?
    private var loopTask:Task<Void,Never>?

    func start() {
        guard !isRunning else{return}; isRunning=true; startedAt=Date()
        loopTask=Task { [weak self] in
            guard let self else{return}; self.jobs=await AlwaysOnJobStore.shared.load()
            while !Task.isCancelled && self.isRunning { await self.tick(); try? await Task.sleep(for:.seconds(1)) }
        }
    }
    func stop(){isRunning=false;loopTask?.cancel();loopTask=nil}

    func schedule(_ job:AlwaysOnJob){ jobs.removeAll{$0.id==job.id}; jobs.append(job); Task{try? await AlwaysOnJobStore.shared.upsert(job)} }
    func pause(_ id:UUID){ mutate(id){$0.state = .paused;$0.isEnabled=false} }
    func resume(_ id:UUID){ mutate(id){$0.state = .scheduled;$0.isEnabled=true;$0.nextRunAt=Date()} }
    func delete(_ id:UUID){jobs.removeAll{$0.id==id};Task{try? await AlwaysOnJobStore.shared.remove(id)}}

    private func mutate(_ id:UUID,_ body:(inout AlwaysOnJob)->Void){guard let i=jobs.firstIndex(where:{$0.id==id})else{return};body(&jobs[i]);jobs[i].updatedAt=Date();let copy=jobs[i];Task{try? await AlwaysOnJobStore.shared.upsert(copy)}}

    private func tick() async {
        lastHeartbeat=Date()
        for index in jobs.indices {
            guard jobs[index].isEnabled, jobs[index].state != .running else{continue}
            let due=jobs[index].nextRunAt ?? jobs[index].createdAt
            guard due <= Date() else{continue}
            let id=jobs[index].id; jobs[index].state = .running; jobs[index].updatedAt=Date(); try? await AlwaysOnJobStore.shared.upsert(jobs[index])
            do { if let onDueJob { try await onDueJob(jobs[index]) }; completeCycle(id) }
            catch { failCycle(id,error:error) }
        }
    }
    private func completeCycle(_ id:UUID){ mutate(id){ job in job.consecutiveFailures=0;job.lastError=nil;if let cadence=job.cadenceSeconds, cadence>0 {job.state = .sleeping;job.nextRunAt=Date().addingTimeInterval(cadence)} else {job.state = .stopped;job.isEnabled=false;job.nextRunAt=nil} } }
    private func failCycle(_ id:UUID,error:Error){ mutate(id){job in job.consecutiveFailures += 1;job.lastError=error.localizedDescription;let delay=min(pow(2,Double(job.consecutiveFailures))*5,300);job.state = .failed;job.nextRunAt=Date().addingTimeInterval(delay)} }
}
