import Foundation

/// Determines which terminal sessions receive one user-entered input event.
/// A checked session is both a member of the broadcast group and an eligible
/// source. This prevents an unchecked terminal from unexpectedly sending its
/// input to another session.
public enum BroadcastInputRouter {
    public static func recipients(
        sourceID: UUID,
        selectedSessionIDs: Set<UUID>,
        readySessionIDs: Set<UUID>
    ) -> Set<UUID> {
        guard selectedSessionIDs.contains(sourceID),
              readySessionIDs.contains(sourceID),
              selectedSessionIDs.count > 1
        else {
            return []
        }

        return selectedSessionIDs
            .intersection(readySessionIDs)
            .subtracting([sourceID])
    }
}
