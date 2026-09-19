import Foundation

struct AIProviderAvailability {
    var hasOpenAI: Bool
    var hasAnthropic: Bool
    var hasOpenRouter: Bool
    var localBaseURL: URL?
    var localModel: String?
    var preferences: AIProviderPreferences
    var hasLocal: Bool { localBaseURL != nil && localModel != nil }
}

/// Central local-first, cost-aware routing policy. It returns an ordered escalation chain.
/// Routine work should be solved by local/Luna, complex work by Terra, and true frontier
/// work by Sol. Historical performance may reorder peers but cannot weaken the safety tier.
struct AIModelRouter {
    func candidates(for prompt:String, context:AIInvocationContext, availability:AIProviderAvailability)->[AIModelSelection]{
        let workload=workload(for:prompt,context:context);guard workload != .deterministic else{return []};var result:[AIModelSelection]=[]
        if availability.hasLocal,[.classification,.routine].contains(workload),let model=availability.localModel {
            result.append(.init(provider:.local,model:model,tier:.local,reasoningEffort:nil,rationale:"Local-first zero-cloud-cost inference"))
        }
        if availability.hasOpenRouter,let model=availability.preferences.openRouterModel(for:workload){
            let tier:AIModelTier;switch workload{case .classification:tier = .economy;case .routine:tier = .standard;case .complex,.verification:tier = .strong;case .frontier,.webResearch:tier = .frontier;case .deterministic:tier = .local}
            result.append(.init(provider:.openRouter,model:model,tier:tier,reasoningEffort:workload == .classification || workload == .routine ? "low":"medium",rationale:"Configured OpenRouter cost-aware route"))
        }
        if availability.hasOpenAI {
            switch workload {
            case .classification:
                result.append(.init(provider:.openAI,model:"gpt-5.6-luna",tier:.economy,reasoningEffort:"low",rationale:"Lowest-cost OpenAI classification"))
            case .routine:
                result.append(.init(provider:.openAI,model:"gpt-5.6-luna",tier:.standard,reasoningEffort:"low",rationale:"Low-cost routine reasoning"))
                result.append(.init(provider:.openAI,model:"gpt-5.6-terra",tier:.strong,reasoningEffort:"low",rationale:"Escalation only if economy route fails"))
            case .complex:
                result.append(.init(provider:.openAI,model:"gpt-5.6-terra",tier:.strong,reasoningEffort:"medium",rationale:"Balanced complex reasoning"))
                result.append(.init(provider:.openAI,model:"gpt-5.6-sol",tier:.frontier,reasoningEffort:"high",rationale:"Frontier escalation for unresolved complex work"))
            case .verification:
                result.append(.init(provider:.openAI,model:"gpt-5.6-terra",tier:.strong,reasoningEffort:"medium",rationale:"Independent verification at balanced cost"))
                result.append(.init(provider:.openAI,model:"gpt-5.6-sol",tier:.frontier,reasoningEffort:"high",rationale:"Escalated verification when needed"))
            case .webResearch:
                result.append(.init(provider:.openAI,model:"gpt-5.6-terra",tier:.strong,reasoningEffort:"medium",rationale:"Research synthesis with cost control"))
                result.append(.init(provider:.openAI,model:"gpt-5.6-sol",tier:.frontier,reasoningEffort:"high",rationale:"Deep research escalation"))
            case .frontier:
                result.append(.init(provider:.openAI,model:"gpt-5.6-sol",tier:.frontier,reasoningEffort:"high",rationale:"Flagship reasoning reserved for frontier tasks"))
            case .deterministic:break
            }
        }
        if availability.hasAnthropic {result.append(.init(provider:.anthropic,model:"claude-sonnet-4-6",tier:workload == .classification ? .standard:.strong,reasoningEffort:nil,rationale:"Cross-provider fallback"))}
        var seen=Set<String>();let deduplicated=result.filter{seen.insert("\($0.provider.rawValue)::\($0.model)").inserted};return adaptiveOrder(deduplicated,workload:workload)
    }

    func workload(for prompt:String,context:AIInvocationContext)->AIWorkloadClass{
        if context.workload != .routine{return context.workload};let value=prompt.lowercased()
        let classificationMarkers=["intent classifier","route one user message","return json only","capabilityid","allowed intents"]
        if classificationMarkers.contains(where:value.contains){return .classification}
        let frontierMarkers=["self-improvement architecture","autonomous self improvement","critical production incident","security architecture","financial risk architecture","multi-agent architecture"]
        if frontierMarkers.contains(where:value.contains){return .frontier}
        let complexMarkers=["planning component","repository-analysis component","repository tree","selected source files","source code","architecture","autonomous runtime","taskplanner","verify the execution"]
        if complexMarkers.contains(where:value.contains){return .complex};return .routine
    }

    private func adaptiveOrder(_ candidates:[AIModelSelection],workload:AIWorkloadClass)->[AIModelSelection]{
        guard candidates.count>1 else{return candidates};let minimumSamples=5,registry=AIAdaptiveRoutingRegistry.shared,breaker=AIModelCircuitBreaker.shared
        let originalIndex=Dictionary(uniqueKeysWithValues:candidates.enumerated().map{("\($0.element.provider.rawValue)::\($0.element.model)",$0.offset)})
        return candidates.sorted{lhs,rhs in
            let lr=safeTierRank(lhs.tier,workload:workload),rr=safeTierRank(rhs.tier,workload:workload);if lr != rr{return lr<rr}
            let lu=breaker.shouldDeprioritize(provider:lhs.provider,model:lhs.model,workload:workload),ru=breaker.shouldDeprioritize(provider:rhs.provider,model:rhs.model,workload:workload);if lu != ru{return !lu}
            let lm=registry.metric(provider:lhs.provider,model:lhs.model,workload:workload),rm=registry.metric(provider:rhs.provider,model:rhs.model,workload:workload),le=lm.flatMap{$0.requestCount>=minimumSamples ? $0:nil},re=rm.flatMap{$0.requestCount>=minimumSamples ? $0:nil}
            switch(le,re){case let(l?,r?):if abs(l.utilityScore-r.utilityScore)>0.01{return l.utilityScore>r.utilityScore};case(_?,nil):return true;case(nil,_?):return false;default:break}
            return (originalIndex["\(lhs.provider.rawValue)::\(lhs.model)"] ?? 0)<(originalIndex["\(rhs.provider.rawValue)::\(rhs.model)"] ?? 0)
        }
    }
    private func safeTierRank(_ tier:AIModelTier,workload:AIWorkloadClass)->Int{
        switch workload{
        case .classification:switch tier{case .local:return 0;case .economy:return 1;case .standard:return 2;case .strong:return 3;case .frontier:return 4}
        case .routine:switch tier{case .local:return 0;case .economy,.standard:return 1;case .strong:return 2;case .frontier:return 3}
        case .complex:switch tier{case .strong:return 0;case .frontier:return 1;case .standard:return 2;case .economy:return 3;case .local:return 4}
        case .verification,.webResearch:switch tier{case .strong:return 0;case .frontier:return 1;case .standard:return 2;case .economy:return 3;case .local:return 4}
        case .frontier:switch tier{case .frontier:return 0;case .strong:return 1;case .standard:return 2;case .economy:return 3;case .local:return 4}
        case .deterministic:return 0}
    }
}
