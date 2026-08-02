import XCTest
@testable import ScanTuneMobile

final class QRPayloadTests: XCTestCase {

    // MARK: - Parsing

    func test_parse_validJSON_returnsPayload() {
        let json = #"{"id":"abc","name":"PC-001","serial":"S123","source":"intune","generated":"2026-05-22"}"#
        let payload = QRPayload.parse(json)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.serial, "S123")
        XCTAssertEqual(payload?.id, "abc")
        XCTAssertEqual(payload?.name, "PC-001")
    }

    func test_parse_nonJSON_returnsNil() {
        XCTAssertNil(QRPayload.parse("plain-serial-number"))
    }

    func test_parse_jsonWithoutSerial_returnsNil() {
        let json = #"{"id":"abc","name":"PC-001"}"#
        XCTAssertNil(QRPayload.parse(json))
    }

    func test_parse_jsonWithEmptySerial_returnsNil() {
        let json = #"{"id":"abc","serial":""}"#
        XCTAssertNil(QRPayload.parse(json))
    }

    func test_parse_ignoresUnknownFields() {
        // Un champ supplémentaire (ex: ancien "sig") ne doit pas empêcher le parsing.
        let json = #"{"id":"abc","serial":"S123","sig":"deadbeef"}"#
        let payload = QRPayload.parse(json)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.serial, "S123")
    }
}
