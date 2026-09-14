import Foundation
import Testing
@testable import OsXtermCore

@Suite
struct TransferTaskPlanningTests {
    @Test
    func sftpPlanAllowsLiteralUnicodeAndNewlinePaths() throws {
        let task = fixture(
            direction: .upload,
            localURL: URL(fileURLWithPath: "/private/tmp/osxterm-fixtures/한글 file"),
            remotePath: "/srv/한글 report\nfinal"
        )

        let plan = try TransferPlanner.plan(
            task,
            allowedLocalRoot: URL(fileURLWithPath: "/private/tmp/osxterm-fixtures")
        )
        #expect(plan.protocolKind == .sftp)
        #expect(plan.operation == .upload)
        #expect(plan.remotePath.rawValue == "/srv/한글 report\nfinal")
    }

    @Test
    func scpPlanRejectsRemoteShellControlCharacters() {
        let task = fixture(
            direction: .scpUpload,
            localURL: URL(fileURLWithPath: "/private/tmp/osxterm-fixtures/file"),
            remotePath: "/srv/report; whoami"
        )

        #expect(throws: TransferPlanningError.remotePathIsUnsafeForSCP("/srv/report; whoami")) {
            _ = try TransferPlanner.plan(task)
        }
    }

    @Test
    func plannerDoesNotLetStandardizationEscapeAllowedRoot() {
        let task = fixture(
            direction: .download,
            localURL: URL(fileURLWithPath: "/private/tmp/allowed/../outside/report"),
            remotePath: "/srv/report"
        )

        #expect(throws: TransferPlanningError.localURLIsOutsideAllowedRoot(URL(fileURLWithPath: "/private/tmp/allowed"))) {
            _ = try TransferPlanner.plan(
                task,
                allowedLocalRoot: URL(fileURLWithPath: "/private/tmp/allowed")
            )
        }
    }

    @Test
    func conflictPolicyAndSafeRenameAreExplicit() throws {
        let destination = URL(fileURLWithPath: "/private/tmp/report.tar.gz")
        #expect(
            try TransferConflictPlanner.decide(
                policy: .ask,
                destinationExists: true,
                destinationURL: destination
            ) == .requiresUserDecision
        )
        #expect(
            try TransferConflictPlanner.decide(
                policy: .skip,
                destinationExists: true,
                destinationURL: destination
            ) == .skip
        )
        #expect(
            try TransferConflictPlanner.decide(
                policy: .rename,
                destinationExists: true,
                destinationURL: destination,
                renameOrdinal: 2
            ) == .rename(URL(fileURLWithPath: "/private/tmp/report.tar 2.gz"))
        )
    }

    @Test
    func stateMachineOnlyCompletesAfterAnActiveTransfer() throws {
        var task = fixture(direction: .download)
        task = try TransferTaskStateMachine.apply(.beginPreparation, to: task)
        task = try TransferTaskStateMachine.apply(.begin(totalBytes: 10), to: task)
        task = try TransferTaskStateMachine.apply(.updateProgress(bytesTransferred: 4, totalBytes: nil), to: task)
        task = try TransferTaskStateMachine.apply(.pause, to: task)
        task = try TransferTaskStateMachine.apply(.resume, to: task)
        task = try TransferTaskStateMachine.apply(.complete, to: task)

        #expect(task.state == .completed)
        #expect(task.bytesTransferred == 10)
        #expect(task.errorMessage == nil)
        #expect(throws: TransferPlanningError.invalidTransferState(.completed, .pause)) {
            _ = try TransferTaskStateMachine.apply(.pause, to: task)
        }
    }

    @Test
    func resumeRequiresTheSameVerifiedSourceFingerprint() {
        let fingerprint = TransferSourceFingerprint(
            size: 100,
            modificationTime: Date(timeIntervalSince1970: 10)
        )
        #expect(
            TransferResumePlanner.decide(
                existingDestinationBytes: 42,
                previousSource: fingerprint,
                currentSource: fingerprint,
                prefixDigestMatches: true
            ) == .resume(fromOffset: 42)
        )
        #expect(
            TransferResumePlanner.decide(
                existingDestinationBytes: 42,
                previousSource: fingerprint,
                currentSource: TransferSourceFingerprint(
                    size: 100,
                    modificationTime: Date(timeIntervalSince1970: 11)
                ),
                prefixDigestMatches: true
            ) == .restart
        )
        #expect(
            TransferResumePlanner.decide(
                existingDestinationBytes: 42,
                previousSource: fingerprint,
                currentSource: fingerprint,
                prefixDigestMatches: false
            ) == .restart
        )
    }

    @Test
    func verifiedCompleteDestinationDoesNotGetTruncatedOnRetry() {
        let fingerprint = TransferSourceFingerprint(
            size: 100,
            modificationTime: Date(timeIntervalSince1970: 10)
        )

        #expect(
            TransferResumePlanner.decide(
                existingDestinationBytes: 100,
                previousSource: fingerprint,
                currentSource: fingerprint,
                prefixDigestMatches: true
            ) == .alreadyComplete
        )
        #expect(
            TransferResumePlanner.decide(
                existingDestinationBytes: 101,
                previousSource: fingerprint,
                currentSource: fingerprint,
                prefixDigestMatches: true
            ) == .restart
        )
    }

    @Test
    func recursiveLedgerKeepsResolvedLeafDestinationAndDirectionSeparate() throws {
        let fingerprint = TransferSourceFingerprint(
            size: 4_096,
            modificationTime: Date(timeIntervalSince1970: 99)
        )
        let localSource = URL(fileURLWithPath: "/private/tmp/osxterm-source/child/../report.txt")
        let remoteSource = try SFTPRemotePath(rawValue: "/srv/source/report.txt")
        let localKey = try RecursiveTransferResumeKey.localFile(at: localSource)
        let remoteKey = RecursiveTransferResumeKey.remoteFile(at: remoteSource)
        let resolvedRemote = try SFTPRemotePath(rawValue: "/srv/target/report (1).txt")
        let resolvedLocal = URL(fileURLWithPath: "/private/tmp/osxterm-target/report (1).txt")
        var ledger = RecursiveTransferResumeLedger()

        ledger.record(
            RecursiveTransferResumeCheckpoint(
                sourceFingerprint: fingerprint,
                destination: .remoteFile(resolvedRemote)
            ),
            for: localKey
        )
        ledger.record(
            RecursiveTransferResumeCheckpoint(
                sourceFingerprint: fingerprint,
                destination: .localFile(resolvedLocal)
            ),
            for: remoteKey
        )

        #expect(
            ledger.checkpoint(for: localKey) == RecursiveTransferResumeCheckpoint(
                sourceFingerprint: fingerprint,
                destination: .remoteFile(resolvedRemote)
            )
        )
        #expect(
            ledger.checkpoint(for: remoteKey) == RecursiveTransferResumeCheckpoint(
                sourceFingerprint: fingerprint,
                destination: .localFile(resolvedLocal)
            )
        )
        #expect(localKey != remoteKey)
    }

    @Test
    func recursiveRetryRetainsRenamedDirectorySeparatelyFromLeafCheckpoints() throws {
        var ledger = RecursiveTransferResumeLedger()
        let key = RecursiveTransferResumeKey.remoteFile(at: try SFTPRemotePath(rawValue: "/srv/project/nested"))
        let renamed = URL(fileURLWithPath: "/private/tmp/download/project (1)/nested (2)")
        ledger.recordDirectory(.localFile(renamed), for: key)
        #expect(ledger.directoryDestination(for: key) == .localFile(renamed))
        #expect(ledger.checkpoint(for: key) == nil)
    }

    @Test
    func retryKeepsTheSourceFingerprintNeededForSafeResume() throws {
        let fingerprint = TransferSourceFingerprint(
            size: 100,
            modificationTime: Date(timeIntervalSince1970: 10)
        )
        var task = fixture(direction: .download)
        task.state = .failed
        task.sourceFingerprint = fingerprint

        task = try TransferTaskStateMachine.apply(.retry, to: task)

        #expect(task.state == .queued)
        #expect(task.sourceFingerprint == fingerprint)
        #expect(task.bytesTransferred == 0)
    }

    @Test
    func retryCheckpointRoundTripsWithoutLosingItsSourceFingerprint() throws {
        let fingerprint = TransferSourceFingerprint(
            size: 4_096,
            modificationTime: Date(timeIntervalSince1970: 1_234)
        )
        var task = fixture(direction: .upload)
        task.state = .failed
        task.sourceFingerprint = fingerprint
        task.retryCount = 1

        let encoded = try JSONEncoder().encode(task)
        let restored = try JSONDecoder().decode(TransferTask.self, from: encoded)

        #expect(restored.sourceFingerprint == fingerprint)
        #expect(restored.state == .failed)
        #expect(restored.retryCount == 1)
    }

    private func fixture(
        direction: TransferDirection,
        localURL: URL = URL(fileURLWithPath: "/private/tmp/osxterm-fixtures/file"),
        remotePath: String = "/srv/file"
    ) -> TransferTask {
        TransferTask(
            profileID: UUID(uuidString: "B9F9A204-3DA0-4CB0-AB46-7BC783823C65")!,
            direction: direction,
            localURL: localURL,
            remotePath: remotePath
        )
    }
}
