import MemoryCapture
import XCTest

final class LaunchAtLoginTests: XCTestCase {
    func testLaunchAtLoginUsesExplicitUserActionAndReportsApproval() async throws {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        let initial = await controller.refresh()
        let initialRegistrationCalls = await service.registrationCallCount()
        XCTAssertEqual(initial.status, .disabled)
        XCTAssertEqual(initialRegistrationCalls, 0)

        await service.setStatusAfterRegistration(.requiresApproval)
        let requested = try await controller.setEnabled(true)
        XCTAssertEqual(requested.status, .requiresApproval)
        XCTAssertEqual(requested.humanGate, .approveInLoginItems)
        let registrationCalls = await service.registrationCallCount()
        XCTAssertEqual(registrationCalls, 1)

        await service.setStatus(.enabled)
        let enabled = await controller.refresh()
        XCTAssertEqual(enabled.status, .enabled)
    }
}

private actor FakeLaunchAtLoginService: LaunchAtLoginServicing {
    private var storedStatus: LaunchAtLoginServiceStatus
    private var statusAfterRegistration: LaunchAtLoginServiceStatus?
    private(set) var registrationCalls = 0

    init(status: LaunchAtLoginServiceStatus) {
        storedStatus = status
    }

    func status() -> LaunchAtLoginServiceStatus {
        storedStatus
    }

    func register() {
        registrationCalls += 1
        if let statusAfterRegistration {
            storedStatus = statusAfterRegistration
        } else {
            storedStatus = .enabled
        }
    }

    func unregister() {
        storedStatus = .notRegistered
    }

    func setStatus(_ status: LaunchAtLoginServiceStatus) {
        storedStatus = status
    }

    func setStatusAfterRegistration(_ status: LaunchAtLoginServiceStatus) {
        statusAfterRegistration = status
    }

    func registrationCallCount() -> Int {
        registrationCalls
    }
}
