import Foundation
import Testing
@testable import OsXtermCore

struct BroadcastInputRouterTests {
    @Test
    func routesInputOnlyToOtherCheckedReadySessions() {
        let source = UUID()
        let firstRecipient = UUID()
        let secondRecipient = UUID()
        let recipients = BroadcastInputRouter.recipients(
            sourceID: source,
            selectedSessionIDs: [source, firstRecipient, secondRecipient],
            readySessionIDs: [source, firstRecipient, secondRecipient]
        )

        #expect(recipients == [firstRecipient, secondRecipient])
    }

    @Test
    func doesNotRouteInputFromAnUncheckedSession() {
        let source = UUID()
        let checkedSession = UUID()
        let recipients = BroadcastInputRouter.recipients(
            sourceID: source,
            selectedSessionIDs: [checkedSession],
            readySessionIDs: [source, checkedSession]
        )

        #expect(recipients.isEmpty)
    }

    @Test
    func excludesUnavailableRecipientsAndRequiresAGroup() {
        let source = UUID()
        let readyRecipient = UUID()
        let unavailableRecipient = UUID()

        let filteredRecipients = BroadcastInputRouter.recipients(
            sourceID: source,
            selectedSessionIDs: [source, readyRecipient, unavailableRecipient],
            readySessionIDs: [source, readyRecipient]
        )
        let singleMemberRecipients = BroadcastInputRouter.recipients(
            sourceID: source,
            selectedSessionIDs: [source],
            readySessionIDs: [source]
        )

        #expect(filteredRecipients == [readyRecipient])
        #expect(singleMemberRecipients.isEmpty)
    }
}
