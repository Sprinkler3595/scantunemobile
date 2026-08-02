import XCTest
@testable import ScanTuneMobile

final class AnomalyDetectorTests: XCTestCase {

    // MARK: - Stale sync

    func test_staleSync_olderThan90Days_isDetected() {
        let oldDevice = makeDevice(
            id: "1",
            serial: "S1",
            lastSync: Date().addingTimeInterval(-91 * 86_400),
            compliant: true
        )
        let anomalies = AnomalyDetector.analyze(devices: [oldDevice], usersByUPN: nil)
        XCTAssertEqual(anomalies.count, 1)
        XCTAssertEqual(anomalies.first?.kind, .staleSync)
    }

    func test_staleSync_within90Days_isNotDetected() {
        let recent = makeDevice(
            id: "1",
            serial: "S1",
            lastSync: Date().addingTimeInterval(-30 * 86_400),
            compliant: true
        )
        let anomalies = AnomalyDetector.analyze(devices: [recent], usersByUPN: nil)
        XCTAssertTrue(anomalies.isEmpty)
    }

    // MARK: - Non-compliant + user actif

    func test_nonCompliant_withActiveUser_isDetected() {
        let device = makeDevice(id: "1", serial: "S1", upn: "alice@corp.com", compliant: false)
        let users = ["alice@corp.com": makeUser(upn: "alice@corp.com", enabled: true)]
        let anomalies = AnomalyDetector.analyze(devices: [device], usersByUPN: users)
        XCTAssertTrue(anomalies.contains { $0.kind == .nonCompliantActiveUser })
    }

    func test_nonCompliant_withDisabledUser_isNotDetected() {
        let device = makeDevice(id: "1", serial: "S1", upn: "alice@corp.com", compliant: false)
        let users = ["alice@corp.com": makeUser(upn: "alice@corp.com", enabled: false)]
        let anomalies = AnomalyDetector.analyze(devices: [device], usersByUPN: users)
        XCTAssertFalse(anomalies.contains { $0.kind == .nonCompliantActiveUser })
    }

    func test_nonCompliant_withoutUsersMap_isNotDetected() {
        let device = makeDevice(id: "1", serial: "S1", upn: "alice@corp.com", compliant: false)
        let anomalies = AnomalyDetector.analyze(devices: [device], usersByUPN: nil)
        XCTAssertFalse(anomalies.contains { $0.kind == .nonCompliantActiveUser })
    }

    // MARK: - Doublons série

    func test_duplicateSerial_acrossTwoDevices_flagsBoth() {
        let a = makeDevice(id: "1", serial: "DUP-1", compliant: true)
        let b = makeDevice(id: "2", serial: "DUP-1", compliant: true)
        let anomalies = AnomalyDetector.analyze(devices: [a, b], usersByUPN: nil)
        let dupAnomalies = anomalies.filter { $0.kind == .duplicateSerial }
        XCTAssertEqual(dupAnomalies.count, 2)
        XCTAssertEqual(Set(dupAnomalies.map(\.deviceId)), ["1", "2"])
    }

    func test_duplicateSerial_caseInsensitive() {
        let a = makeDevice(id: "1", serial: "abc-123", compliant: true)
        let b = makeDevice(id: "2", serial: "ABC-123", compliant: true)
        let anomalies = AnomalyDetector.analyze(devices: [a, b], usersByUPN: nil)
        XCTAssertEqual(anomalies.filter { $0.kind == .duplicateSerial }.count, 2)
    }

    func test_emptySerial_doesNotTriggerDuplicate() {
        let a = makeDevice(id: "1", serial: "", compliant: true)
        let b = makeDevice(id: "2", serial: "", compliant: true)
        let anomalies = AnomalyDetector.analyze(devices: [a, b], usersByUPN: nil)
        XCTAssertTrue(anomalies.filter { $0.kind == .duplicateSerial }.isEmpty)
    }

    // MARK: - Index

    func test_indexByDevice_groupsCorrectly() {
        let a = makeDevice(id: "1", serial: "DUP", lastSync: Date().addingTimeInterval(-100 * 86_400), compliant: true)
        let b = makeDevice(id: "2", serial: "DUP", compliant: true)
        let anomalies = AnomalyDetector.analyze(devices: [a, b], usersByUPN: nil)
        let index = AnomalyDetector.indexByDevice(anomalies)
        XCTAssertEqual(index["1"]?.count, 2) // staleSync + duplicateSerial
        XCTAssertEqual(index["2"]?.count, 1) // duplicateSerial only
    }

    // MARK: - Helpers

    private func makeDevice(
        id: String,
        serial: String,
        upn: String = "",
        lastSync: Date = Date(),
        compliant: Bool = true
    ) -> Device {
        Device(
            id: id,
            deviceName: "DEV-\(id)",
            managedDeviceOwnerType: "company",
            operatingSystem: "Windows",
            osVersion: "11",
            complianceState: compliant ? "compliant" : "noncompliant",
            model: "ModelX",
            manufacturer: "Acme",
            serialNumber: serial,
            userPrincipalName: upn,
            userDisplayName: "",
            enrolledDateTime: nil,
            lastSyncDateTime: lastSync,
            totalStorageSpaceInBytes: 0,
            freeStorageSpaceInBytes: 0,
            managementAgent: "mdm",
            deviceRegistrationState: "registered",
            azureADDeviceId: "",
            deviceCategoryDisplayName: "",
            notes: ""
        )
    }

    private func makeUser(upn: String, enabled: Bool) -> User {
        User(
            id: UUID().uuidString,
            displayName: "Test User",
            userPrincipalName: upn,
            mail: upn,
            jobTitle: "",
            department: "",
            companyName: "Corp",
            officeLocation: "",
            mobilePhone: "",
            accountEnabled: enabled
        )
    }
}
