// Minimal App Store Connect API client: `swift scripts/asc.swift <path>` prints the JSON for GET /v1/<path>.
// Credentials: ~/.appstoreconnect/scriptorium.env (ASC_KEY_ID, ASC_ISSUER_ID) and
// ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
import CryptoKit
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let env = (try? String(contentsOf: home.appending(path: ".appstoreconnect/scriptorium.env"), encoding: .utf8)) ?? ""
var config: [String: String] = [:]
for line in env.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { config[parts[0]] = parts[1] }
}
guard let keyID = config["ASC_KEY_ID"], let issuer = config["ASC_ISSUER_ID"] else { print("missing credentials"); exit(1) }
let pem = try String(contentsOf: home.appending(path: ".appstoreconnect/private_keys/AuthKey_\(keyID).p8"), encoding: .utf8)
let key = try P256.Signing.PrivateKey(pemRepresentation: pem)

func b64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let now = Int(Date().timeIntervalSince1970)
let header = b64(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"]))
let claims = b64(try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"]))
let signature = try key.signature(for: Data("\(header).\(claims)".utf8))
let token = "\(header).\(claims).\(b64(signature.rawRepresentation))"

let path = CommandLine.arguments.dropFirst().first ?? "apps"
var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/\(path)")!)
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
let semaphore = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: request) { data, response, error in
    if let error { print("error: \(error)") }
    print("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    if let data { print(String(decoding: data, as: UTF8.self)) }
    semaphore.signal()
}.resume()
semaphore.wait()
