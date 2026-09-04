import Foundation

actor AlwaysOnJobStore {
    static let shared = AlwaysOnJobStore()
    private struct Snapshot: Codable { var version=1; var savedAt=Date(); var jobs:[AlwaysOnJob] }
    private let url: URL

    init(fileManager: FileManager = .default) {
        let base=(try? fileManager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)) ?? fileManager.temporaryDirectory
        let dir=base.appendingPathComponent("TRAVIS/AlwaysOn",isDirectory:true)
        try? fileManager.createDirectory(at:dir,withIntermediateDirectories:true)
        url=dir.appendingPathComponent("jobs-v1.json")
    }

    func load() -> [AlwaysOnJob] { guard let data=try? Data(contentsOf:url) else{return []}; let d=JSONDecoder(); d.dateDecodingStrategy = .iso8601; return (try? d.decode(Snapshot.self,from:data).jobs) ?? [] }
    func save(_ jobs:[AlwaysOnJob]) throws { let e=JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting=[.sortedKeys]; try e.encode(Snapshot(jobs:jobs)).write(to:url,options:.atomic) }
    func upsert(_ job:AlwaysOnJob) throws { var jobs=load(); if let i=jobs.firstIndex(where:{$0.id==job.id}){jobs[i]=job}else{jobs.append(job)}; try save(jobs) }
    func remove(_ id:UUID) throws { var jobs=load(); jobs.removeAll{$0.id==id}; try save(jobs) }
}
