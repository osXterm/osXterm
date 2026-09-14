import Foundation

/// Determines which terminal sessions receive one user-entered input event.
/// A checked session is both a member of the broadcast group and an eligible
/// source. This prevents an unchecked terminal from unexpectedly sending its
/// input to another session.
public enum BroadcastInputRouter {
    /// Keeps only currently ready sessions in a broadcast selection. Callers
    /// use this when a terminal disconnects so a reconnect never silently
    /// resumes a previously active broadcast group.
    public static func activeSessionIDs(
        selectedSessionIDs: Set<UUID>,
        readySessionIDs: Set<UUID>
    ) -> Set<UUID> {
        selectedSessionIDs.intersection(readySessionIDs)
    }

    public static func recipients(
        sourceID: UUID,
        selectedSessionIDs: Set<UUID>,
        readySessionIDs: Set<UUID>
    ) -> Set<UUID> {
        let activeSessionIDs = activeSessionIDs(
            selectedSessionIDs: selectedSessionIDs,
            readySessionIDs: readySessionIDs
        )
        guard activeSessionIDs.contains(sourceID), activeSessionIDs.count > 1
        else {
            return []
        }

        return activeSessionIDs.subtracting([sourceID])
    }
}
