import Foundation

struct WindowsProviderSnapshotPublicationOutcome: Equatable, Sendable {
  let rejectedProviders: Set<WindowsProviderID>

  var requiresRefresh: Bool { !self.rejectedProviders.isEmpty }
}

/// Revalidates and commits one provider at a time. No call holds more than one provider mutex.
enum WindowsProviderSnapshotPublisher {
  static func publish(
    _ snapshots: [WindowsProviderSnapshot],
    commit: (WindowsProviderSnapshot) -> Void
  ) -> WindowsProviderSnapshotPublicationOutcome {
    var rejectedProviders = Set<WindowsProviderID>()
    for snapshot in snapshots {
      do {
        let didCommit = try WindowsProviderOperationLock.withLock(
          provider: snapshot.provider,
          timeoutMilliseconds: 0
        ) {
          guard try snapshot.publicationAuthorityCheck?() ?? true else { return false }
          commit(snapshot)
          return true
        }
        if !didCommit {
          rejectedProviders.insert(snapshot.provider)
        }
      } catch {
        rejectedProviders.insert(snapshot.provider)
      }
    }
    return WindowsProviderSnapshotPublicationOutcome(rejectedProviders: rejectedProviders)
  }
}
