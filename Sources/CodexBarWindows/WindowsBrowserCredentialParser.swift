import Foundation

struct WindowsBrowserCredentialPolicy: Sendable, Equatable {
  enum Input: Sendable, Equatable {
    case cookieHeader
    case cookieHeaderOrCURL
    case fullRequest(allowCookieHeader: Bool)
    case opaqueSession(defaultCookieName: String, recognizedCookieNames: [String])
  }

  let input: Input
  let acceptedHosts: [String]
  let requiredCookieNames: [String]
  let requiredCookieNamePrefixes: [String]
  let requiresAllCookieNames: Bool
  let forwardedHeaders: [String: String]
  let requiredHeaders: [String]
  let exactPath: String?
  let allowsQuery: Bool
  let cookieRequired: Bool

  init(
    input: Input,
    acceptedHosts: [String],
    requiredCookieNames: [String] = [],
    requiredCookieNamePrefixes: [String] = [],
    requiresAllCookieNames: Bool = false,
    forwardedHeaders: [String: String] = [:],
    requiredHeaders: [String] = [],
    exactPath: String? = nil,
    allowsQuery: Bool = true,
    cookieRequired: Bool = true
  ) {
    self.input = input
    self.acceptedHosts = acceptedHosts.map { $0.lowercased() }
    self.requiredCookieNames = requiredCookieNames
    self.requiredCookieNamePrefixes = requiredCookieNamePrefixes
    self.requiresAllCookieNames = requiresAllCookieNames
    self.forwardedHeaders = Dictionary(
      uniqueKeysWithValues: forwardedHeaders.map { ($0.key.lowercased(), $0.value) })
    self.requiredHeaders = requiredHeaders.map { $0.lowercased() }
    self.exactPath = exactPath
    self.allowsQuery = allowsQuery
    self.cookieRequired = cookieRequired
  }
}

struct WindowsBrowserCredentialValidationResult: Sendable, Equatable {
  let normalizedValue: String?
  let summary: String

  var isValid: Bool {
    self.normalizedValue != nil
  }

  static func valid(_ value: String, summary: String) -> Self {
    Self(normalizedValue: value, summary: summary)
  }

  static func invalid(_ summary: String) -> Self {
    Self(normalizedValue: nil, summary: summary)
  }
}

enum WindowsBrowserCredentialParser {
  static let maximumInputBytes = 65536

  static func validate(
    _ rawValue: String,
    policy: WindowsBrowserCredentialPolicy
  ) -> WindowsBrowserCredentialValidationResult {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return .invalid("Missing credential value") }
    guard value.utf8.count <= Self.maximumInputBytes else {
      return .invalid("Credential value is too large")
    }
    guard !value.contains("\0") else { return .invalid("Credential value contains invalid data") }

    switch policy.input {
    case .cookieHeader:
      return Self.validateCookieInput(value, policy: policy, acceptsCURL: true)
    case .cookieHeaderOrCURL:
      return Self.validateCookieInput(value, policy: policy, acceptsCURL: true)
    case .fullRequest(let allowCookieHeader):
      if !Self.looksLikeCURL(value) {
        guard allowCookieHeader else { return .invalid("Full cURL request required") }
        return Self.validateCookieInput(value, policy: policy, acceptsCURL: false)
      }
      return Self.validateFullRequest(value, policy: policy)
    case .opaqueSession(let defaultCookieName, let recognizedCookieNames):
      return Self.validateOpaqueSession(
        value,
        policy: policy,
        defaultCookieName: defaultCookieName,
        recognizedCookieNames: recognizedCookieNames)
    }
  }

  private static func validateCookieInput(
    _ value: String,
    policy: WindowsBrowserCredentialPolicy,
    acceptsCURL: Bool
  ) -> WindowsBrowserCredentialValidationResult {
    var rawCookie = value
    var summary = "Detected: Cookie header"
    if Self.looksLikeCURL(value) {
      guard acceptsCURL else { return .invalid("Cookie header required") }
      let capture: CURLCapture
      switch Self.parseCURL(value) {
      case .success(let parsed): capture = parsed
      case .failure(let message): return .invalid(message)
      }
      guard let host = Self.validatedHost(capture.url, policy: policy) else {
        return .invalid("Request URL must use an approved HTTPS host")
      }
      guard let cookie = capture.cookieHeader else { return .invalid("Missing Cookie header") }
      rawCookie = cookie
      summary = "Detected: cURL request for \(host)"
    } else if value.lowercased().hasPrefix("cookie:") {
      rawCookie = String(value.dropFirst("cookie:".count))
    }

    guard let cookie = Self.canonicalCookieHeader(rawCookie) else {
      return .invalid("Malformed Cookie header")
    }
    guard Self.hasRequiredCookies(cookie, policy: policy) else {
      return .invalid("Missing required session cookie")
    }
    return .valid(cookie, summary: summary)
  }

  private static func validateFullRequest(
    _ value: String,
    policy: WindowsBrowserCredentialPolicy
  ) -> WindowsBrowserCredentialValidationResult {
    let capture: CURLCapture
    switch Self.parseCURL(value) {
    case .success(let parsed): capture = parsed
    case .failure(let message): return .invalid(message)
    }
    guard let host = Self.validatedHost(capture.url, policy: policy) else {
      return .invalid("Request URL must use an approved HTTPS host")
    }
    if let exactPath = policy.exactPath, capture.url.path != exactPath {
      return .invalid("Captured request path is not supported")
    }
    if !policy.allowsQuery, capture.url.query != nil {
      return .invalid("Captured request query is not supported")
    }

    let cookie: String?
    if let rawCookie = capture.cookieHeader {
      guard let normalized = Self.canonicalCookieHeader(rawCookie) else {
        return .invalid("Malformed Cookie header")
      }
      cookie = normalized
    } else {
      cookie = nil
    }
    guard !policy.cookieRequired || cookie != nil else { return .invalid("Missing Cookie header") }
    if let cookie, !Self.hasRequiredCookies(cookie, policy: policy) {
      return .invalid("Missing required session cookie")
    }

    var retained: [String: String] = [:]
    for (name, value) in capture.headers {
      guard let canonicalName = policy.forwardedHeaders[name] else { continue }
      retained[canonicalName] = value
    }
    for required in policy.requiredHeaders
    where retained.keys.allSatisfy({ $0.lowercased() != required }) {
      return .invalid("Missing \(policy.forwardedHeaders[required] ?? required) header")
    }
    if let cookie { retained["Cookie"] = cookie }

    let canonical = Self.canonicalCURL(url: capture.url, headers: retained)
    return .valid(canonical, summary: "Detected: cURL request for \(host)")
  }

  private static func validateOpaqueSession(
    _ value: String,
    policy: WindowsBrowserCredentialPolicy,
    defaultCookieName: String,
    recognizedCookieNames: [String]
  ) -> WindowsBrowserCredentialValidationResult {
    if self.looksLikeCURL(value) || value.lowercased().hasPrefix("cookie:") || value.contains("=") {
      let result = Self.validateCookieInput(value, policy: policy, acceptsCURL: true)
      guard result.isValid else { return result }
      return result
    }
    guard !value.contains(";"), !value.contains(where: { $0.isWhitespace || $0.isNewline }),
      !value.contains(where: { $0.isASCII && $0.asciiValue.map { $0 < 0x21 || $0 == 0x7F } == true }
      )
    else { return .invalid("Unrecognized session value") }
    let policyNames = Set(recognizedCookieNames.map { $0.lowercased() })
    guard policyNames.contains(defaultCookieName.lowercased()) else {
      return .invalid("Unrecognized session value")
    }
    return .valid(
      "\(defaultCookieName)=\(value)",
      summary: "Detected: session value")
  }

  private static func hasRequiredCookies(
    _ cookieHeader: String,
    policy: WindowsBrowserCredentialPolicy
  ) -> Bool {
    guard !policy.requiredCookieNames.isEmpty || !policy.requiredCookieNamePrefixes.isEmpty else {
      return true
    }
    let names = Set(Self.cookiePairs(cookieHeader).map { $0.name.lowercased() })
    let exactRequirements = policy.requiredCookieNames.map { $0.lowercased() }
    let prefixRequirements = policy.requiredCookieNamePrefixes.map { $0.lowercased() }
    let matches: [Bool] =
      exactRequirements.map { expected in
        names.contains { Self.cookieName($0, matches: expected) }
      }
      + prefixRequirements.map { prefix in
        names.contains { $0.hasPrefix(prefix) }
      }
    return policy.requiresAllCookieNames
      ? matches.allSatisfy { $0 }
      : matches.contains(true)
  }

  private static func cookieName(_ actual: String, matches required: String) -> Bool {
    if actual == required { return true }
    guard required.hasSuffix("session-token") else { return false }
    let prefix = "\(required)."
    guard actual.hasPrefix(prefix) else { return false }
    return Int(actual.dropFirst(prefix.count)) != nil
  }

  private static func canonicalCookieHeader(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains(where: \.isNewline) else { return nil }
    let pairs = Self.cookiePairs(value)
    guard !pairs.isEmpty else { return nil }
    let components = value.split(separator: ";", omittingEmptySubsequences: false)
    guard components.count == pairs.count else { return nil }
    var seen: Set<String> = []
    for pair in pairs {
      let lowercased = pair.name.lowercased()
      guard seen.insert(lowercased).inserted else { return nil }
    }
    return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  private static func cookiePairs(_ raw: String) -> [(name: String, value: String)] {
    raw.split(separator: ";", omittingEmptySubsequences: false).compactMap { component in
      let part = component.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !part.isEmpty, let equals = part.firstIndex(of: "=") else { return nil }
      let name = part[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
      let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
      guard !name.isEmpty, name.rangeOfCharacter(from: separators) == nil,
        name.rangeOfCharacter(from: .controlCharacters) == nil,
        value.rangeOfCharacter(from: .controlCharacters) == nil
      else { return nil }
      return (String(name), String(value))
    }
  }

  private struct CURLCapture {
    let url: URL
    let cookieHeader: String?
    let headers: [String: String]
  }

  private enum ParseResult {
    case success(CURLCapture)
    case failure(String)
  }

  private static func parseCURL(_ raw: String) -> ParseResult {
    guard let tokens = curlTokens(raw), !tokens.isEmpty,
      tokens[0].caseInsensitiveCompare("curl") == .orderedSame
    else { return .failure("Malformed cURL request") }

    var index = 1
    var urlText: String?
    var headerFields: [String] = []
    var cookieArgument: String?
    while index < tokens.count {
      let token = tokens[index]
      let lowercased = token.lowercased()
      if lowercased == "-h" || lowercased == "--header" {
        index += 1
        guard index < tokens.count else { return .failure("Malformed cURL header option") }
        headerFields.append(tokens[index])
      } else if lowercased.hasPrefix("--header=") {
        headerFields.append(String(token.dropFirst("--header=".count)))
      } else if lowercased == "-b" || lowercased == "--cookie" {
        index += 1
        guard index < tokens.count else { return .failure("Malformed cURL cookie option") }
        guard cookieArgument == nil else {
          return .failure("Multiple Cookie values are not supported")
        }
        cookieArgument = tokens[index]
      } else if lowercased.hasPrefix("--cookie=") {
        guard cookieArgument == nil else {
          return .failure("Multiple Cookie values are not supported")
        }
        cookieArgument = String(token.dropFirst("--cookie=".count))
      } else if lowercased == "--url" {
        index += 1
        guard index < tokens.count, urlText == nil else {
          return .failure("Exactly one request URL is required")
        }
        urlText = tokens[index]
      } else if lowercased.hasPrefix("--url=") {
        guard urlText == nil else { return .failure("Exactly one request URL is required") }
        urlText = String(token.dropFirst("--url=".count))
      } else if lowercased == "--compressed" {
        // Browser-generated transport hint; discarded from the canonical capture.
      } else if token.hasPrefix("-") {
        return .failure("Unsupported cURL option")
      } else {
        guard urlText == nil else { return .failure("Exactly one request URL is required") }
        urlText = token
      }
      index += 1
    }

    guard let urlText, let url = URL(string: urlText), url.scheme != nil, url.host != nil else {
      return .failure("Missing request URL")
    }
    var headers: [String: String] = [:]
    for field in headerFields {
      guard let colon = field.firstIndex(of: ":") else { return .failure("Malformed cURL header") }
      let name = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = field[field.index(after: colon)...].trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard Self.isHeaderName(String(name)), !value.isEmpty,
        value.rangeOfCharacter(from: .controlCharacters) == nil
      else { return .failure("Malformed cURL header") }
      let lowercased = name.lowercased()
      guard headers[String(lowercased)] == nil else { return .failure("Duplicate cURL header") }
      headers[String(lowercased)] = String(value)
    }
    let headerCookie = headers.removeValue(forKey: "cookie")
    guard headerCookie == nil || cookieArgument == nil else {
      return .failure("Multiple Cookie values are not supported")
    }
    let cookie = headerCookie ?? cookieArgument
    guard cookie?.hasPrefix("@") != true else {
      return .failure("Cookie file references are not supported")
    }
    return .success(CURLCapture(url: url, cookieHeader: cookie, headers: headers))
  }

  private static func curlTokens(_ raw: String) -> [String]? {
    enum Quote { case none, single, double, ansi }
    var quote = Quote.none
    var escaping = false
    var current = ""
    var tokens: [String] = []
    var index = raw.startIndex

    func appendCurrent() {
      guard !current.isEmpty else { return }
      tokens.append(current)
      current = ""
    }

    while index < raw.endIndex {
      let character = raw[index]
      let nextIndex = raw.index(after: index)
      if escaping {
        escaping = false
        if character != "\n", character != "\r" { current.append(character) }
        index = nextIndex
        continue
      }
      switch quote {
      case .none:
        if character == "\\" {
          escaping = true
        } else if character == "'" {
          quote = .single
        } else if character == "\"" {
          quote = .double
        } else if character == "$", nextIndex < raw.endIndex, raw[nextIndex] == "'" {
          quote = .ansi
          index = raw.index(after: nextIndex)
          continue
        } else if [";", "|", "&", ">", "<", "`"].contains(character) {
          return nil
        } else if character == "$", nextIndex < raw.endIndex, raw[nextIndex] == "(" {
          return nil
        } else if character.isWhitespace {
          appendCurrent()
        } else {
          current.append(character)
        }
      case .single:
        if character == "'" { quote = .none } else { current.append(character) }
      case .double:
        if character == "\"" {
          quote = .none
        } else if character == "\\" {
          escaping = true
        } else if character == "`"
          || (character == "$" && nextIndex < raw.endIndex && raw[nextIndex] == "(")
        {
          return nil
        } else {
          current.append(character)
        }
      case .ansi:
        if character == "'" {
          quote = .none
        } else if character == "\\" {
          escaping = true
        } else {
          current.append(character)
        }
      }
      index = nextIndex
    }
    guard quote == .none, !escaping else { return nil }
    appendCurrent()
    return tokens
  }

  private static func validatedHost(
    _ url: URL,
    policy: WindowsBrowserCredentialPolicy
  ) -> String? {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      url.port == nil, url.fragment == nil,
      let host = url.host(percentEncoded: false)?.lowercased(),
      policy.acceptedHosts.contains(host)
    else { return nil }
    return host
  }

  private static func canonicalCURL(url: URL, headers: [String: String]) -> String {
    var components = ["curl \(Self.singleQuoted(url.absoluteString))"]
    for name in headers.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
      guard let value = headers[name] else { continue }
      // The unchanged CLI's CookieHeaderNormalizer recognizes the compact -H
      // form without retaining the closing shell quote in the cookie value.
      components.append("-H \(Self.singleQuoted("\(name): \(value)"))")
    }
    return components.joined(separator: " ")
  }

  private static func singleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func isHeaderName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
    return value.rangeOfCharacter(from: separators) == nil
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private static func looksLikeCURL(_ value: String) -> Bool {
    value.prefix(4).caseInsensitiveCompare("curl") == .orderedSame
      && value.dropFirst(4).first.map(\.isWhitespace) == true
  }
}
