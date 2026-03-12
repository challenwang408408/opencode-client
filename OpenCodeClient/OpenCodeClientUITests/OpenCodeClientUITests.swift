//
//  OpenCodeClientUITests.swift
//  OpenCodeClientUITests
//
//  Created by Yan Wang on 2/12/26.
//

import XCTest

final class OpenCodeClientUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()
    }

    /// 2.3 ChatTabView baseline: 验证 Chat 页加载后输入框可见（refactor 后用此测试回归）
    @MainActor
    func testChatTabShowsInputField() throws {
        let app = XCUIApplication()
        app.launch()
        let askField = app.descendants(matching: .any)["chat-input-field"]
        XCTAssertTrue(askField.waitForExistence(timeout: 8), "Chat 输入框应可见")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
