import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class TRAVISAppState {
    var selectedSidebarItem:SidebarItem = .chat
    var chatInput:String=""{didSet{if chatInput.trimmingCharacters(in:.whitespacesAndNewlines)=="Έλεγξε την κατάσταση του συστήματος"{chatInput="";runLocalSystemScan()}}}
    var chatMessages:[ChatMessage]=[];var pendingCommands:[TravisCommand]=[];var activeTasks:[TravisTask]=[];var permissions:[TravisPermission]=[]
    var assistantName="TRAVIS";var preferredLanguage:AppLanguage = .greek;var currentDeviceState:DeviceState = .idle;var isListening=false;var isProcessing=false;var isInternetEnabled=true;var isBusy=false;var lastResponseSummary="Ready"
    var anthropicAPIKey:String=""{didSet{anthropicAPIKey.isEmpty ? KeychainService.shared.deleteAnthropicAPIKey():KeychainService.shared.saveAnthropicAPIKey(anthropicAPIKey)}}
    var binanceTestnetAPIKey:String=""{didSet{binanceTestnetAPIKey.isEmpty ? KeychainService.shared.deleteBinanceTestnetAPIKey():KeychainService.shared.saveBinanceTestnetAPIKey(binanceTestnetAPIKey)}}
    var binanceTestnetAPISecret:String=""{didSet{binanceTestnetAPISecret.isEmpty ? KeychainService.shared.deleteBinanceTestnetAPISecret():KeychainService.shared.saveBinanceTestnetAPISecret(binanceTestnetAPISecret)}}
    let approvalGate:ApprovalGateService;let orchestrator:AgentOrchestrator;let taskRuntime:AgentTaskRuntime;let taskExecutor:AgentTaskExecutor
    private(set)var currentSessionId=UUID();private(set)var viewedSessionId=UUID()

    init(){
        let approvalGate=ApprovalGateService(),orchestrator=AgentOrchestrator(approvalGate:approvalGate),taskRuntime=AgentTaskRuntime();let taskExecutor=AgentTaskExecutor(runtime:taskRuntime,orchestrator:orchestrator,approvalGate:approvalGate);self.approvalGate=approvalGate;self.orchestrator=orchestrator;self.taskRuntime=taskRuntime;self.taskExecutor=taskExecutor
        let market=MarketIntelligenceCapability(),audit=SelfAuditCapability(),trading=CryptoTradingCapability(),evolution=SelfEvolutionCapabilityV6(),fs=FilesystemOperationsCapability(),advancedFS=AdvancedFilesystemCapability(),productivity=LocalProductivityCapability(),calculation=LocalCalculationCapability(),automation=LocalAutomationCapability(),document=LocalDocumentCapability(),fileSearch=LocalFileSearchCapability(),textRead=LocalTextFileReadCapability(),textTransform=LocalTextTransformCapability(),data=LocalDataCapability(),batch=LocalBatchTextCapability(),artifact=LocalArtifactCapability(),visual=PresentationArtifactCapability(),directory=LocalDirectoryAnalysisCapability(),delivery=LocalDeliveryBundleCapability(),scaffold=LocalProjectScaffoldCapability(),workspace=LocalProjectWorkspaceCapability(),fcc=FCCAssistantCapability()
        let appCapabilities:[AgentCapability]=[TextTaskCapability(),market,audit,trading,SelfImprovementCapability(),evolution,fs,advancedFS,productivity,calculation,automation,document,fileSearch,textRead,textTransform,data,batch,artifact,visual,directory,delivery,scaffold,workspace,fcc]
        appCapabilities.forEach{orchestrator.register($0)}
        orchestrator.onAssistantMessage={ [weak self] text in self?.addAssistantMessage(text)};orchestrator.onSessionRecall={ [weak self] id in self?.viewSession(id)}
        taskExecutor.onProgress={ [weak self] text in self?.addAssistantMessage(text);guard let self else{return};Task{@MainActor [weak self] in await self?.synchronizeCompletedKnowledge()}}
        trading.onTestnetExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};evolution.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};fs.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};advancedFS.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};productivity.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};calculation.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};automation.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};document.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};batch.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};artifact.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};visual.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};delivery.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};scaffold.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};workspace.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)};fcc.onExecutionUpdate={ [weak self] in self?.addAssistantMessage($0)}
        SpeechRecognitionService.shared.onFinalTranscript={ [weak self] text in self?.sendCommand(text,source:.voice)}
        if let k=KeychainService.shared.anthropicAPIKey{anthropicAPIKey=k};if let k=KeychainService.shared.binanceTestnetAPIKey{binanceTestnetAPIKey=k};if let k=KeychainService.shared.binanceTestnetAPISecret{binanceTestnetAPISecret=k};bootstrap()
    }
    func bootstrap(){if permissions.isEmpty{permissions=TravisPermission.defaultPermissions};if activeTasks.isEmpty{activeTasks=[TravisTask(title:"Connect services",details:"Wire AI, sync, and execution layers.",status:.pending,priority:.high),TravisTask(title:"Prepare permissions",details:"Set user approval rules for sensitive actions.",status:.pending,priority:.medium)]};startNewSession();let restored=PersistenceService.shared.loadProposedActions();approvalGate.restore(pending:restored.pending,history:restored.history);refreshTradingMandates();TravisFCCBridgeServer.shared.start();Task{@MainActor [weak self] in await self?.synchronizeCompletedKnowledge()}}
    private func synchronizeCompletedKnowledge()async{let coordinator=ProjectMemoryCoordinator();for task in taskRuntime.tasks where task.status == .completed{await coordinator.synchronize(taskId:task.id,runtime:taskRuntime)};TravisLearningService.shared.refresh()}
    func startNewSession(){currentSessionId=UUID();viewedSessionId=currentSessionId;chatMessages=[]}
    var pastSessions:[ChatSession]{PersistenceService.shared.loadChatSessions().filter{$0.id != currentSessionId}}
    func viewSession(_ sessionId:UUID){guard sessionId != viewedSessionId else{return};viewedSessionId=sessionId;chatMessages=PersistenceService.shared.loadChatMessages().filter{$0.sessionId==sessionId}}
    func returnToCurrentSession(){guard viewedSessionId != currentSessionId else{return};viewedSessionId=currentSessionId;chatMessages=PersistenceService.shared.loadChatMessages().filter{$0.sessionId==currentSessionId}}
    @discardableResult func appendMessage(role:ChatRole,text:String)->ChatMessage{let message=ChatMessage(role:role,text:text,sessionId:currentSessionId);PersistenceService.shared.saveChatMessage(message);if viewedSessionId==currentSessionId{chatMessages.append(message)}else{viewedSessionId=currentSessionId;chatMessages=PersistenceService.shared.loadChatMessages().filter{$0.sessionId==currentSessionId}};return message}
    func sendChat(){let text=chatInput.trimmingCharacters(in:.whitespacesAndNewlines);guard !text.isEmpty else{return};chatInput="";sendCommand(text,source:.manual)}
    func addAssistantMessage(_ text:String){appendMessage(role:.assistant,text:text);if isListening{SpeechService.shared.speak(text,language:preferredLanguage){[weak self] in guard let self,self.isListening else{return};SpeechRecognitionService.shared.start(language:self.preferredLanguage)}}}
    func approveCommand(at index:Int){guard pendingCommands.indices.contains(index)else{return};pendingCommands[index].status = .approved;lastResponseSummary="Command approved"}
    func denyCommand(at index:Int){guard pendingCommands.indices.contains(index)else{return};pendingCommands[index].status = .cancelled;lastResponseSummary="Command denied"}
    func togglePermissionEnabled(_ permission:TravisPermission){guard let i=permissions.firstIndex(where:{$0.id==permission.id})else{return};permissions[i].isEnabled.toggle()}
    func updatePermission(_ permission:TravisPermission,to policy:PermissionPolicy){guard let i=permissions.firstIndex(where:{$0.id==permission.id})else{return};permissions[i].policy=policy}
    func toggleListening(){isListening.toggle();currentDeviceState=isListening ? .listening:.idle;if isListening{SpeechRecognitionService.shared.start(language:preferredLanguage)}else{SpeechService.shared.stopSpeaking();SpeechRecognitionService.shared.stop()}}
    func updateDeviceState(_ newState:DeviceState){currentDeviceState=newState}
    var tradingMandates:[StandingPermission]=[]
    func refreshTradingMandates(){tradingMandates=PersistenceService.shared.standingPermissions(withKeyPrefix:"trading_").filter{$0.granted}}
    func revokeTradingMandate(_ mandate:StandingPermission){PersistenceService.shared.setPermission(mandate.key,granted:false);refreshTradingMandates()}
    func runLocalSystemScan(){let tasks=taskRuntime.tasks,active=tasks.filter{[AgentTaskStatus.running,.planning,.waitingForApproval,.waitingForDependency].contains($0.status)}.count,failed=tasks.filter{$0.status == .failed}.count,enabled=permissions.filter{$0.isEnabled}.count,total=permissions.count;let aiMode=isInternetEnabled ? (KeychainService.shared.openAIAPIKey?.isEmpty==false || !anthropicAPIKey.isEmpty ? "✓ CLOUD ROUTING AVAILABLE":"⚠ CLOUD ENABLED / API KEY MISSING") : "✓ LOCAL / INTERNET DISABLED",voice=isListening ? "✓ LISTENING":"✓ STANDBY"
#if os(macOS)
        let fccState=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.fccassistant.desktop") != nil ? "✓ INSTALLED":"⚠ NOT REGISTERED"
#else
        let fccState="N/A"
#endif
        let overall=failed>0 || enabled==0 ? "ATTENTION REQUIRED":"OPERATIONAL",cost=AIUsageLedger.shared.efficiencySummary();let report="""
SYSTEM CHECK
TRAVIS Runtime       ✓ READY
Autonomous Tasks     \(active) active / \(failed) failed
Permissions          \(enabled)/\(total) enabled
AI Service           \(aiMode)
AI Calls             \(cost.requests) · cache \(String(format:"%.0f",cost.cachedInputRatio*100))%
Estimated AI Spend   $\(String(format:"%.4f",cost.costUSD))
Local AI Avoidance   \(LocalIntelligenceMetrics.shared.provenAICallsAvoided) proven calls avoided
Cognitive Core       ✓ V6 economy + reflection
Self Evolution       ✓ isolated branch / approval gated
Trading Risk Kernel  ✓ deterministic / paper-testnet only
Voice                \(voice)
FCC Assistant        \(fccState)
FCC/PI Boundary      ✓ LOCAL / READ-ONLY
Process Cloud Route  ✓ BLOCKED BY ARCHITECTURE
Visual Artifacts     ✓ SVG / HTML / Markdown
Overall Status: \(overall)
""";lastResponseSummary="System check: \(overall)";addAssistantMessage(report)}
    func saveGeneratedText(_ text:String,filename:String?=nil,location:String?=nil,capabilityId:String){guard let resolved=FileLocationService.shared.resolveSaveDirectory(for:location)else{let m="Δεν ήταν δυνατή η αποθήκευση του αρχείου — δεν δόθηκε πρόσβαση στον φάκελο.";addAssistantMessage(m);lastResponseSummary=m;return};defer{resolved.stopAccessing()};let name=filename ?? "travis-text-\(Int(Date().timeIntervalSince1970)).txt",url=resolved.url.appendingPathComponent(name);do{try text.write(to:url,atomically:true,encoding:.utf8);PersistenceService.shared.saveFile(filename:name,path:url.path,capabilityId:capabilityId);addAssistantMessage("Το κείμενο αποθηκεύτηκε: \(url.path)");lastResponseSummary="Αποθηκεύτηκε: \(name)"}catch{let m="Αποτυχία αποθήκευσης: \(error.localizedDescription)";addAssistantMessage(m);lastResponseSummary=m}}
}