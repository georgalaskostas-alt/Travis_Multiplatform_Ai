import Foundation
import Security

/// Narrow Keychain storage for the signed-in TRAVIS cloud session.
/// The Supabase publishable key is public configuration; user access tokens are secrets and live here only.
enum TravisCloudCredentialStore {
    private static let service = "com.travis.control-plane"
    private static let account = "supabase-user-access-token"

    static func save(accessToken:String) throws {
        let data=Data(accessToken.utf8)
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        SecItemDelete(query as CFDictionary)
        var add=query;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status=SecItemAdd(add as CFDictionary,nil);guard status==errSecSuccess else{throw StoreError.status(status)}
    }
    static func load()->String? {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let data=item as? Data else{return nil};return String(data:data,encoding:.utf8)
    }
    static func clear(){let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account];SecItemDelete(q as CFDictionary)}
    enum StoreError:LocalizedError{case status(OSStatus);var errorDescription:String?{switch self{case let .status(s):return "Keychain error \(s)"}}}
}
