import Foundation

struct GitHubFileSnapshot:Hashable{let path:String;let sha:String;let content:String}
enum GitHubCodingServiceError:LocalizedError{case missingToken,invalidURL,invalidResponse,http(status:Int,message:String),nonTextFile,invalidPath,invalidBranch;var errorDescription:String?{switch self{case .missingToken:return"Δεν υπάρχει GitHub token στις Ρυθμίσεις.";case .invalidURL:return"Μη έγκυρο GitHub API URL.";case .invalidResponse:return"Μη αναμενόμενη απάντηση από το GitHub API.";case .http(let status,let message):return"GitHub API HTTP \(status): \(message)";case .nonTextFile:return"Το GitHub αρχείο δεν αποκωδικοποιήθηκε ως UTF-8 text.";case .invalidPath:return"Μη ασφαλές repository path.";case .invalidBranch:return"Μη ασφαλές GitHub branch name."}}}

/// Low-level transport for TRAVIS's own repository. Reads may be autonomous; writes are
/// only reachable from approved ProposedAction resolution and use SHA optimistic locking.
/// V6 additionally supports isolated self-improvement branches; it never merges them.
final class GitHubCodingService {
    static let shared=GitHubCodingService()
    let repository="georgalaskostas-alt/Travis_Multiplatform_Ai"
    private let session:URLSession
    private let defaults:UserDefaults
    private static let branchKey="travis.github.codingBranch"
    var branch:String{let configured=defaults.string(forKey:Self.branchKey)?.trimmingCharacters(in:.whitespacesAndNewlines);return configured?.isEmpty==false ? configured!:"agent/iphone-live-task-control"}
    init(session:URLSession = .shared,defaults:UserDefaults = .standard){self.session=session;self.defaults=defaults}
    func setBranch(_ value:String){let v=value.trimmingCharacters(in:.whitespacesAndNewlines);guard Self.safeBranch(v) else{return};defaults.set(v,forKey:Self.branchKey)}

    func fetchFile(path:String,ref:String?=nil)async throws->GitHubFileSnapshot{
        guard Self.safePath(path)else{throw GitHubCodingServiceError.invalidPath};let target=ref ?? branch;guard Self.safeBranch(target)else{throw GitHubCodingServiceError.invalidBranch}
        let encoded=Self.encoded(path);guard var c=URLComponents(string:"https://api.github.com/repos/\(repository)/contents/\(encoded)")else{throw GitHubCodingServiceError.invalidURL};c.queryItems=[URLQueryItem(name:"ref",value:target)];guard let url=c.url else{throw GitHubCodingServiceError.invalidURL};var request=URLRequest(url:url);decorate(&request,requiresToken:false);let(data,response)=try await session.data(for:request);try validate(response:response,data:data);guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let sha=object["sha"] as? String,let b64=object["content"] as? String,let decoded=Data(base64Encoded:b64.replacingOccurrences(of:"\n",with:"")),let text=String(data:decoded,encoding:.utf8)else{throw GitHubCodingServiceError.nonTextFile};return .init(path:path,sha:sha,content:text)
    }

    func branchHeadSHA(_ name:String)async throws->String{
        guard Self.safeBranch(name)else{throw GitHubCodingServiceError.invalidBranch};guard let url=URL(string:"https://api.github.com/repos/\(repository)/git/ref/heads/\(Self.encodedBranch(name))")else{throw GitHubCodingServiceError.invalidURL};var request=URLRequest(url:url);decorate(&request,requiresToken:false);let(data,response)=try await session.data(for:request);try validate(response:response,data:data);guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let target=object["object"] as? [String:Any],let sha=target["sha"] as? String else{throw GitHubCodingServiceError.invalidResponse};return sha
    }

    /// Creates an isolated branch from a known base. A 422 "already exists" is
    /// treated as idempotent only when the branch can subsequently be resolved.
    @discardableResult func createBranch(name:String,from base:String?=nil)async throws->String{
        guard Self.safeBranch(name)else{throw GitHubCodingServiceError.invalidBranch};let source=base ?? branch;guard Self.safeBranch(source)else{throw GitHubCodingServiceError.invalidBranch};let baseSHA=try await branchHeadSHA(source);guard let token=Self.token()else{throw GitHubCodingServiceError.missingToken};guard let url=URL(string:"https://api.github.com/repos/\(repository)/git/refs")else{throw GitHubCodingServiceError.invalidURL};var request=URLRequest(url:url);request.httpMethod="POST";decorate(&request,requiresToken:true,token:token);request.httpBody=try JSONSerialization.data(withJSONObject:["ref":"refs/heads/\(name)","sha":baseSHA]);let(data,response)=try await session.data(for:request);if let http=response as? HTTPURLResponse,http.statusCode==422 { return try await branchHeadSHA(name) };try validate(response:response,data:data);return baseSHA
    }

    @discardableResult func replaceFile(path:String,expectedSHA:String,newContent:String,commitMessage:String,branchOverride:String?=nil)async throws->String{
        guard Self.safePath(path)else{throw GitHubCodingServiceError.invalidPath};guard let token=Self.token()else{throw GitHubCodingServiceError.missingToken};let target=branchOverride ?? branch;guard Self.safeBranch(target)else{throw GitHubCodingServiceError.invalidBranch};guard let url=URL(string:"https://api.github.com/repos/\(repository)/contents/\(Self.encoded(path))")else{throw GitHubCodingServiceError.invalidURL};var request=URLRequest(url:url);request.httpMethod="PUT";decorate(&request,requiresToken:true,token:token);request.httpBody=try JSONSerialization.data(withJSONObject:["message":String(commitMessage.prefix(180)),"content":Data(newContent.utf8).base64EncodedString(),"sha":expectedSHA,"branch":target]);let(data,response)=try await session.data(for:request);try validate(response:response,data:data);guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let commit=object["commit"] as? [String:Any],let sha=commit["sha"] as? String else{throw GitHubCodingServiceError.invalidResponse};return sha
    }

    func improvementBranchName(seed:String)->String{
        let slug=seed.lowercased().folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).split{!$0.isLetter && !$0.isNumber}.prefix(6).joined(separator:"-")
        let stamp=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"").replacingOccurrences(of:"-",with:"").prefix(15)
        return "travis/improve-\(slug.isEmpty ? "runtime":slug)-\(stamp)"
    }

    private func decorate(_ request:inout URLRequest,requiresToken:Bool,token:String?=nil){request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version");let credential=token ?? Self.token();if let credential{request.setValue("Bearer \(credential)",forHTTPHeaderField:"Authorization")}else if requiresToken{return}}
    private func validate(response:URLResponse,data:Data)throws{guard let http=response as? HTTPURLResponse else{throw GitHubCodingServiceError.invalidResponse};guard (200..<300).contains(http.statusCode)else{let msg=(try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["message"] as? String ?? String(data:data,encoding:.utf8) ?? "unknown error";throw GitHubCodingServiceError.http(status:http.statusCode,message:msg)}}
    private static func token()->String?{let v=KeychainService.shared.githubToken?.trimmingCharacters(in:.whitespacesAndNewlines);return v?.isEmpty==false ? v:nil}
    private static func encoded(_ path:String)->String{path.split(separator:"/").map{String($0).addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? String($0)}.joined(separator:"/")}
    private static func encodedBranch(_ branch:String)->String{branch.split(separator:"/").map{String($0).addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? String($0)}.joined(separator:"/")}
    private static func safePath(_ path:String)->Bool{let p=path.trimmingCharacters(in:.whitespacesAndNewlines);return !p.isEmpty && !p.hasPrefix("/") && !p.contains("..") && !p.contains("\\") && !p.contains("\0")}
    private static func safeBranch(_ value:String)->Bool{let v=value.trimmingCharacters(in:.whitespacesAndNewlines);guard !v.isEmpty,!v.hasPrefix("/"),!v.hasSuffix("/"),!v.contains(".."),!v.contains(" "),!v.contains("\\"),!v.contains("~"),!v.contains("^") else{return false};return v.count<=180}
}
