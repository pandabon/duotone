import Foundation
import Security

public protocol SandboxDetecting: Sendable {
  func isSandboxed(appAt url: URL) -> Bool
}

/// Reads the app-sandbox entitlement from the code signature. The signature is not validated
/// (that is the expensive part); an unsigned or broken bundle simply reads as not sandboxed.
public struct CodeSignatureSandboxDetector: SandboxDetecting {
  public init() {}

  public func isSandboxed(appAt url: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSRequirementInformation)
    guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    else { return false }
    return entitlements["com.apple.security.app-sandbox"] as? Bool == true
  }
}
