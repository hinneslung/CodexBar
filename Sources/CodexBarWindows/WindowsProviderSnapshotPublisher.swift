import Foundation

struct WindowsProviderSnapshotPublicationOutcome: Equatable, Sendable {
    let rejectedProviders: Set<WindowsProviderID>
    let rejectedProfiles: Set<WindowsProviderProfileID>

    var requiresRefresh: Bool {
        !self.rejectedProfiles.isEmpty
    }
}

/// Revalidates and commits one provider at a time. No call holds more than one provider mutex.
enum WindowsProviderSnapshotPublisher {
    static func publish(
        _ snapshots: [WindowsProviderSnapshot],
        commit: (WindowsProviderSnapshot) -> Void) -> WindowsProviderSnapshotPublicationOutcome
    {
        var rejectedProviders = Set<WindowsProviderID>()
        var rejectedProfiles = Set<WindowsProviderProfileID>()
        for snapshot in snapshots {
            do {
                let didCommit = try WindowsProviderOperationLock.withLock(
                    profileID: snapshot.profileID,
                    timeoutMilliseconds: 0)
                {
                    guard try snapshot.publicationAuthorityCheck?() ?? true else { return false }
                    commit(snapshot)
                    return true
                }
                if !didCommit {
                    rejectedProviders.insert(snapshot.provider)
                    rejectedProfiles.insert(snapshot.profileID)
                }
            } catch {
                rejectedProviders.insert(snapshot.provider)
                rejectedProfiles.insert(snapshot.profileID)
            }
        }
        return WindowsProviderSnapshotPublicationOutcome(
            rejectedProviders: rejectedProviders,
            rejectedProfiles: rejectedProfiles)
    }
}
