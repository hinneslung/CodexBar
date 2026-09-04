import Foundation
import WinSDK

struct WindowsHiddenProcessResult: Sendable {
  let standardOutput: Data
  let standardError: Data
  let exitCode: Int32
}

enum WindowsHiddenProcessRunner {
  static let creationFlags = DWORD(
    CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED)

  static func run(
    executablePath: String,
    arguments: [String],
    timeout: TimeInterval,
    maximumOutputBytes: Int,
    environmentOverrides: [String: String] = [:],
    standardInput: Data? = nil
  ) throws -> WindowsHiddenProcessResult {
    let executable = URL(fileURLWithPath: executablePath)
    guard FileManager.default.fileExists(atPath: executable.path) else {
      throw WindowsCanonicalCLIError.executableUnavailable
    }
    guard maximumOutputBytes >= 0 else { throw WindowsCanonicalCLIError.outputTooLarge }

    var security = SECURITY_ATTRIBUTES()
    security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
    security.bInheritHandle = true
    var outputHandles = try Self.openOutput(security: &security)
    defer { Self.close(handles: &outputHandles) }
    var errorHandles = try Self.openOutput(security: &security)
    defer { Self.close(handles: &errorHandles) }
    let inputHandles = try Self.openInput(standardInput, security: &security)
    var childInput: HANDLE? = inputHandles.child
    var parentInput = inputHandles.parent
    defer {
      if let childInput { _ = CloseHandle(childInput) }
      if let parentInput { _ = CloseHandle(parentInput) }
    }

    var startup = STARTUPINFOEXW()
    startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
    startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES) | DWORD(STARTF_USESHOWWINDOW)
    startup.StartupInfo.wShowWindow = WORD(SW_HIDE)
    startup.StartupInfo.hStdInput = childInput
    startup.StartupInfo.hStdOutput = outputHandles.child
    startup.StartupInfo.hStdError = errorHandles.child
    let attributeList = try Self.inheritedHandleList(
      handles: [childInput, outputHandles.child, errorHandles.child].compactMap { $0 })
    defer { attributeList.destroy() }
    startup.lpAttributeList = attributeList.pointer
    var process = PROCESS_INFORMATION()
    let job = try WindowsKillOnCloseJob()
    defer { job.close() }
    var commandLine = Array(
      Self.commandLine(executablePath: executable.path, arguments: arguments).utf16)
    commandLine.append(0)
    var environmentBlock = try Self.environmentBlock(
      base: ProcessInfo.processInfo.environment,
      overrides: environmentOverrides)
    let launched = WindowsWideString.withPointer(executable.path) { applicationName in
      commandLine.withUnsafeMutableBufferPointer { buffer in
        environmentBlock.withUnsafeMutableBufferPointer { environment in
          withUnsafeMutablePointer(to: &startup) { startupPointer in
            let startupInfoPointer = UnsafeMutableRawPointer(startupPointer)
              .assumingMemoryBound(to: STARTUPINFOW.self)
            return CreateProcessW(
              applicationName,
              buffer.baseAddress,
              nil,
              nil,
              true,
              Self.creationFlags,
              environment.baseAddress.map(UnsafeMutableRawPointer.init),
              nil,
              startupInfoPointer,
              &process)
          }
        }
      }
    }
    guard launched else { throw WindowsCanonicalCLIError.launchFailed }
    defer {
      _ = CloseHandle(process.hThread)
      _ = CloseHandle(process.hProcess)
    }
    guard job.assign(process: process.hProcess), ResumeThread(process.hThread) != DWORD.max else {
      _ = TerminateProcess(process.hProcess, UINT(ERROR_PROCESS_ABORTED))
      throw WindowsCanonicalCLIError.launchFailed
    }
    if let childInput { _ = CloseHandle(childInput) }
    childInput = nil
    if let childOutput = outputHandles.child { _ = CloseHandle(childOutput) }
    outputHandles.child = nil
    if let childError = errorHandles.child { _ = CloseHandle(childError) }
    errorHandles.child = nil
    let milliseconds = DWORD(min(max(timeout * 1000, 1), Double(DWORD.max - 1)))
    let deadline = GetTickCount64() &+ ULONGLONG(milliseconds)
    var workers: [WindowsPipeWorker] = []
    defer {
      for worker in workers { _ = CloseHandle(worker.thread) }
    }
    do {
      let outputReader = try WindowsPipeWorker.reading(
        handle: outputHandles.parent,
        maximumBytes: maximumOutputBytes)
      outputHandles.parent = nil
      workers.append(outputReader)
      let errorReader = try WindowsPipeWorker.reading(
        handle: errorHandles.parent,
        maximumBytes: maximumOutputBytes)
      errorHandles.parent = nil
      workers.append(errorReader)
      if let standardInput, let input = parentInput {
        let inputWriter = try WindowsPipeWorker.writing(handle: input, data: standardInput)
        parentInput = nil
        workers.append(inputWriter)
        try Self.wait(for: inputWriter, deadline: deadline)
      }
      try Self.wait(for: process.hProcess, deadline: deadline)
      for worker in workers where worker.operation.kind.isReader {
        try Self.wait(for: worker, deadline: deadline)
      }
    } catch {
      Self.stop(process: process.hProcess, workers: workers)
      throw error
    }
    var exitCode: DWORD = 0
    guard GetExitCodeProcess(process.hProcess, &exitCode) else {
      throw WindowsCanonicalCLIError.launchFailed
    }
    guard workers.count >= 2,
      !workers[0].operation.outputExceededLimit,
      !workers[1].operation.outputExceededLimit
    else {
      throw WindowsCanonicalCLIError.outputTooLarge
    }
    return WindowsHiddenProcessResult(
      standardOutput: workers[0].operation.output,
      standardError: workers[1].operation.output,
      exitCode: Int32(bitPattern: exitCode))
  }

  static func commandLine(executablePath: String, arguments: [String]) -> String {
    ([executablePath] + arguments).map(Self.quote).joined(separator: " ")
  }

  static func environmentBlock(
    base: [String: String],
    overrides: [String: String]
  ) throws -> [WCHAR] {
    var environment: [String: (key: String, value: String)] = [:]
    for (key, value) in base {
      try Self.validateEnvironment(key: key, value: value)
      environment[key.lowercased()] = (key, value)
    }
    for (key, value) in overrides {
      try Self.validateEnvironment(key: key, value: value)
      environment[key.lowercased()] = (key, value)
    }
    let entries = environment.values.sorted {
      $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
    }
    var block: [WCHAR] = []
    for entry in entries {
      block.append(contentsOf: "\(entry.key)=\(entry.value)".utf16)
      block.append(0)
    }
    block.append(0)
    return block
  }

  private static func validateEnvironment(key: String, value: String) throws {
    guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
      throw WindowsCanonicalCLIError.invalidEnvironment
    }
  }

  private static func quote(_ argument: String) -> String {
    guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" })
    else { return argument }
    var result = "\""
    var backslashes = 0
    for character in argument {
      if character == "\\" {
        backslashes += 1
      } else if character == "\"" {
        result += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
        backslashes = 0
      } else {
        result += String(repeating: "\\", count: backslashes) + String(character)
        backslashes = 0
      }
    }
    return result + String(repeating: "\\", count: backslashes * 2) + "\""
  }

  private static func openOutput(
    security: inout SECURITY_ATTRIBUTES
  ) throws -> (child: HANDLE?, parent: HANDLE?) {
    var readHandle: HANDLE?
    var writeHandle: HANDLE?
    guard CreatePipe(&readHandle, &writeHandle, &security, 0),
      let readHandle,
      let writeHandle,
      SetHandleInformation(readHandle, DWORD(HANDLE_FLAG_INHERIT), 0)
    else {
      if let readHandle { _ = CloseHandle(readHandle) }
      if let writeHandle { _ = CloseHandle(writeHandle) }
      throw WindowsCanonicalCLIError.launchFailed
    }
    return (writeHandle, readHandle)
  }

  private static func openNullInput(security: inout SECURITY_ATTRIBUTES) -> HANDLE? {
    let handle = WindowsWideString.withPointer("NUL") { path in
      CreateFileW(
        path,
        DWORD(GENERIC_READ),
        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
        &security,
        DWORD(OPEN_EXISTING),
        DWORD(FILE_ATTRIBUTE_NORMAL),
        nil)
    }
    return handle == INVALID_HANDLE_VALUE ? nil : handle
  }

  static func openInput(
    _ data: Data?,
    security: inout SECURITY_ATTRIBUTES
  ) throws -> (child: HANDLE, parent: HANDLE?) {
    guard data != nil else {
      guard let input = Self.openNullInput(security: &security) else {
        throw WindowsCanonicalCLIError.launchFailed
      }
      return (input, nil)
    }
    var readHandle: HANDLE?
    var writeHandle: HANDLE?
    guard CreatePipe(&readHandle, &writeHandle, &security, 0),
      let readHandle,
      let writeHandle,
      SetHandleInformation(writeHandle, DWORD(HANDLE_FLAG_INHERIT), 0)
    else {
      if let readHandle { _ = CloseHandle(readHandle) }
      if let writeHandle { _ = CloseHandle(writeHandle) }
      throw WindowsCanonicalCLIError.launchFailed
    }
    return (readHandle, writeHandle)
  }

  private static func wait(for worker: WindowsPipeWorker, deadline: ULONGLONG) throws {
    try Self.wait(for: worker.thread, deadline: deadline)
    guard worker.operation.succeeded else {
      throw WindowsCanonicalCLIError.launchFailed
    }
  }

  private static func wait(for handle: HANDLE, deadline: ULONGLONG) throws {
    while true {
      if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
        throw WindowsCanonicalCLIError.cancelled
      }
      let remaining = Self.remainingMilliseconds(until: deadline)
      if remaining == 0 { throw WindowsCanonicalCLIError.timedOut }
      let wait = WaitForSingleObject(handle, min(remaining, 100))
      if wait == DWORD(WAIT_OBJECT_0) { return }
      if wait != DWORD(WAIT_TIMEOUT) { throw WindowsCanonicalCLIError.launchFailed }
    }
  }

  private static func remainingMilliseconds(until deadline: ULONGLONG) -> DWORD {
    let now = GetTickCount64()
    guard now < deadline else { return 0 }
    return DWORD(min(deadline - now, ULONGLONG(DWORD.max - 1)))
  }

  private static func stop(process: HANDLE, workers: [WindowsPipeWorker]) {
    _ = TerminateProcess(process, UINT(ERROR_TIMEOUT))
    for worker in workers { worker.cancel() }
    _ = WaitForSingleObject(process, 1_000)
    for worker in workers { _ = WaitForSingleObject(worker.thread, 1_000) }
  }

  private static func close(handles: inout (child: HANDLE?, parent: HANDLE?)) {
    if let child = handles.child { _ = CloseHandle(child) }
    if let parent = handles.parent { _ = CloseHandle(parent) }
    handles = (nil, nil)
  }

  private static func inheritedHandleList(
    handles: [HANDLE]
  ) throws -> WindowsProcessAttributeList {
    try WindowsProcessAttributeList(handles: handles)
  }
}

private final class WindowsKillOnCloseJob {
  private var handle: HANDLE?

  init() throws {
    guard let handle = CreateJobObjectW(nil, nil) else {
      throw WindowsCanonicalCLIError.launchFailed
    }
    var information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    information.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
    let configured = withUnsafeMutablePointer(to: &information) { pointer in
      SetInformationJobObject(
        handle,
        JobObjectExtendedLimitInformation,
        UnsafeMutableRawPointer(pointer),
        DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
    }
    guard configured else {
      _ = CloseHandle(handle)
      throw WindowsCanonicalCLIError.launchFailed
    }
    self.handle = handle
  }

  func assign(process: HANDLE) -> Bool {
    guard let handle = self.handle else { return false }
    return AssignProcessToJobObject(handle, process)
  }

  func close() {
    if let handle = self.handle { _ = CloseHandle(handle) }
    self.handle = nil
  }
}

private final class WindowsProcessAttributeList {
  // WinSDK imports this macro as unavailable to Swift. This is
  // ProcThreadAttributeValue(ProcThreadAttributeHandleList, FALSE, TRUE, FALSE).
  private static let handleListAttribute = DWORD_PTR(0x0002_0002)

  let pointer: LPPROC_THREAD_ATTRIBUTE_LIST
  private let memory: UnsafeMutableRawPointer
  private let handles: UnsafeMutablePointer<HANDLE>
  private let handleCount: Int

  init(handles: [HANDLE]) throws {
    self.handleCount = handles.count
    self.handles = .allocate(capacity: handles.count)
    self.handles.initialize(from: handles, count: handles.count)
    var size: SIZE_T = 0
    _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
    guard size > 0 else {
      self.handles.deinitialize(count: self.handleCount)
      self.handles.deallocate()
      throw WindowsCanonicalCLIError.launchFailed
    }
    self.memory = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: 16)
    self.pointer = OpaquePointer(self.memory)
    guard InitializeProcThreadAttributeList(self.pointer, 1, 0, &size) else {
      self.memory.deallocate()
      self.handles.deinitialize(count: self.handleCount)
      self.handles.deallocate()
      throw WindowsCanonicalCLIError.launchFailed
    }
    let updated = UpdateProcThreadAttribute(
      self.pointer,
      0,
      Self.handleListAttribute,
      self.handles,
      SIZE_T(self.handleCount * MemoryLayout<HANDLE>.stride),
      nil,
      nil)
    guard updated else {
      DeleteProcThreadAttributeList(self.pointer)
      self.memory.deallocate()
      self.handles.deinitialize(count: self.handleCount)
      self.handles.deallocate()
      throw WindowsCanonicalCLIError.launchFailed
    }
  }

  func destroy() {
    DeleteProcThreadAttributeList(self.pointer)
    self.memory.deallocate()
    self.handles.deinitialize(count: self.handleCount)
    self.handles.deallocate()
  }
}

private final class WindowsPipeOperation: @unchecked Sendable {
  enum Kind {
    case read(maximumBytes: Int)
    case write(Data)

    var isReader: Bool {
      if case .read = self { return true }
      return false
    }
  }

  let kind: Kind
  private let lock = NSLock()
  private var handle: HANDLE?
  private(set) var output = Data()
  private(set) var outputExceededLimit = false
  private(set) var succeeded = false

  init(handle: HANDLE, kind: Kind) {
    self.handle = handle
    self.kind = kind
  }

  func run() -> DWORD {
    defer { self.closeHandle() }
    let result: Bool =
      switch self.kind {
      case .read(let maximumBytes):
        self.read(maximumBytes: maximumBytes)
      case .write(let data):
        self.write(data)
      }
    self.succeeded = result
    return result ? 0 : 1
  }

  func cancel() {
    self.lock.lock()
    let handle = self.handle
    self.lock.unlock()
    if let handle { _ = CancelIoEx(handle, nil) }
  }

  private func read(maximumBytes: Int) -> Bool {
    guard let handle = self.currentHandle() else { return false }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      var count: DWORD = 0
      let read = buffer.withUnsafeMutableBytes { bytes in
        ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &count, nil)
      }
      if !read {
        let error = GetLastError()
        return error == DWORD(ERROR_BROKEN_PIPE) || error == DWORD(ERROR_OPERATION_ABORTED)
      }
      if count == 0 { return true }
      let available = maximumBytes + 1 - self.output.count
      if available > 0 {
        self.output.append(contentsOf: buffer.prefix(min(Int(count), available)))
      }
      if self.output.count > maximumBytes { self.outputExceededLimit = true }
    }
  }

  private func write(_ data: Data) -> Bool {
    guard let handle = self.currentHandle() else { return false }
    return data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        var written: DWORD = 0
        let chunk = min(bytes.count - offset, Int(DWORD.max))
        guard
          WriteFile(
            handle,
            bytes.baseAddress?.advanced(by: offset),
            DWORD(chunk),
            &written,
            nil), written > 0
        else { return false }
        offset += Int(written)
      }
      return true
    }
  }

  private func currentHandle() -> HANDLE? {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.handle
  }

  private func closeHandle() {
    self.lock.lock()
    let handle = self.handle
    self.handle = nil
    self.lock.unlock()
    if let handle { _ = CloseHandle(handle) }
  }
}

private struct WindowsPipeWorker {
  let thread: HANDLE
  let operation: WindowsPipeOperation

  static func reading(handle: HANDLE?, maximumBytes: Int) throws -> Self {
    guard let handle else { throw WindowsCanonicalCLIError.launchFailed }
    return try self.start(.init(handle: handle, kind: .read(maximumBytes: maximumBytes)))
  }

  static func writing(handle: HANDLE, data: Data) throws -> Self {
    try self.start(.init(handle: handle, kind: .write(data)))
  }

  func cancel() {
    _ = CancelSynchronousIo(self.thread)
    self.operation.cancel()
  }

  private static func start(_ operation: WindowsPipeOperation) throws -> Self {
    let retained = Unmanaged.passRetained(operation)
    guard
      let thread = CreateThread(
        nil,
        0,
        windowsHiddenProcessPipeThread,
        retained.toOpaque(),
        0,
        nil)
    else {
      retained.release()
      throw WindowsCanonicalCLIError.launchFailed
    }
    return Self(thread: thread, operation: operation)
  }
}

private func windowsHiddenProcessPipeThread(_ context: LPVOID?) -> DWORD {
  guard let context else { return 1 }
  return Unmanaged<WindowsPipeOperation>.fromOpaque(context).takeRetainedValue().run()
}
