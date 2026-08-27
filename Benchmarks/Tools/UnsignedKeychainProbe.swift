import Foundation
import Security
import Darwin

struct ProbeResult: Codable {
    let role: String
    let status: Int32
    let keyHashMatched: Bool
}

guard CommandLine.arguments.count == 5 else {
    Darwin.exit(64)
}
let accessGroup = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
let account = CommandLine.arguments[3]
let output = URL(fileURLWithPath: CommandLine.arguments[4])
var result: CFTypeRef?
let status = SecItemCopyMatching([
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccessGroup as String: accessGroup,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
    kSecUseDataProtectionKeychain as String: true,
] as CFDictionary, &result)
let report = ProbeResult(role: "unsigned", status: status, keyHashMatched: false)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: output, options: .atomic)
