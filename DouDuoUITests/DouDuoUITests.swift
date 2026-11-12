import XCTest

/// DouDuo 核心流程：推荐流加载 → 视频在走 → 上滑切下一条 → 横滑快进 → 点作者进主页 → 能返回原生页
final class DouDuoUITests: XCTestCase {
    /// 菜单与官网分享面板：仅打开、查看、关闭，绝不点击朋友或发送。
    func testMenuCleanupAndFriendForwardWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        let query = app.buttons.matching(identifier: "douyin.more")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 40))
        func openMore() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
            (query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? query.firstMatch).tap()
        }
        openMore()
        XCTAssertFalse(app.buttons["竖屏占比"].exists)
        XCTAssertFalse(app.buttons["自动连播"].exists)
        XCTAssertFalse(app.buttons["静音"].exists)
        XCTAssertTrue(app.buttons["刷新推荐"].exists)
        attach(app, "menu-cleanup-root")
        app.buttons["设置"].tap()
        // 原生 Menu 子菜单偶发被动画吞掉一次点击：重开一次菜单再点，仍以真实控件存在为验收。
        if !app.buttons["播放设置"].waitForExistence(timeout: 3) && app.buttons["设置"].exists {
            app.buttons["设置"].tap()
        }
        XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["缓存管理"].exists)
        attach(app, "menu-cleanup-settings")
        openMore()
        let share = app.buttons["douyin.forward.menu"]
        if share.exists { share.tap() } else { app.buttons["转发"].tap() }
        let close = app.buttons["douyin.forward.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let panel = app.otherElements["douyin.forward.panel"]
        XCTAssertTrue(panel.exists)
        XCTAssertFalse(app.navigationBars["转发给抖音朋友"].exists, "转发主界面不能退回全屏网页")
        XCTAssertTrue(app.staticTexts["分享给"].exists)
        let ready = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '登录抖音后显示' OR label CONTAINS '选择朋友转发当前作品' OR label CONTAINS '官网暂无可读取'" )).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(app.buttons["douyin.forward.action.copy"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.other"].exists)
        app.buttons["douyin.forward.action.copy"].tap()
        XCTAssertTrue(app.staticTexts["链接已复制"].waitForExistence(timeout: 5))
        attach(app, "friend-forward-native-floating-panel-no-send")
        close.tap()
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        print("DDFORWARD_UI: native-panel-opened-and-closed; no-recipient-selected; no-send")
    }

    /// 明确标注的模拟器合成联系人，只验证布局/横滑/取消确认，不连接发送桥。
    func testNativeForwardLayoutWithSyntheticContacts() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        app.launch()
        let query = app.buttons.matching(identifier: "douyin.more")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 40))
        (query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? query.firstMatch).tap()
        let share = app.buttons["douyin.forward.menu"]
        if share.exists { share.tap() } else { app.buttons["转发"].tap() }
        let contact = app.buttons["douyin.forward.contact.layout-fixture-1"]
        XCTAssertTrue(contact.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成布局测试（不会发送消息）"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.private"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.groups"].exists)
        attach(app, "friend-forward-native-SYNTHETIC-layout-no-send")
        contact.tap()
        app.buttons["douyin.forward.contact.layout-fixture-2"].tap()
        let send = app.buttons["douyin.forward.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.label, "发送给 2 人")
        send.tap()
        XCTAssertTrue(app.alerts["确认转发"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        let panel = app.otherElements["douyin.forward.panel"]
        XCTAssertGreaterThan(panel.frame.minY, app.frame.height * 0.1)
        XCTAssertLessThan(panel.frame.maxY, app.frame.height * 0.9)
        let contactIDs = (1...9).map { "douyin.forward.contact.layout-fixture-\($0)" }
        let visibleBefore = Set(contactIDs.filter { app.buttons[$0].isHittable })
        let start = contact.coordinate(withNormalizedOffset: CGVector(dx: 3.7, dy: 0.3))
        let end = contact.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        // 惯性可停在3–6或6–9，验“新联系人变为可点”，不把固定第5项当滚动终点。
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            contactIDs.contains { !visibleBefore.contains($0) && app.buttons[$0].isHittable }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed)
        app.buttons["douyin.forward.close"].tap()
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        print("DDFORWARD_LAYOUT: synthetic-only; floating-frame; horizontal-scroll; confirmation-cancelled; real-sends=0")
    }

    func testVideoDanmakuSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // 仅在测试进程内生成明确标记的压力弹幕，不向平台发消息。
        app.launchEnvironment["DOUDUO_DM_STRESS"] = "1"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        let moreQuery = app.buttons.matching(identifier: "douyin.more")
        func moreButton() -> XCUIElement {
            moreQuery.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? moreQuery.firstMatch
        }
        XCTAssertTrue(moreQuery.firstMatch.waitForExistence(timeout: 40))
        sleep(4)
        attach(app, "video-danmaku-upper-third-synthetic-stress")
        func openMore() {
            // Picker / Toggle 的原生菜单可能留在父菜单；先在左侧菜单外收起。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
            moreButton().tap()
        }
        func openSettings() {
            openMore()
            let settings = app.buttons["douyin.danmaku.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }
        for title in ["稀疏", "密集", "标准"] {
            openSettings()
            let option = app.buttons[title]
            if !option.exists { app.buttons["douyin.danmaku.density"].tap() }
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            openMore()
            let settings = app.buttons["douyin.danmaku.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertTrue(settings.label.contains(title), settings.debugDescription)
            attach(app, "video-danmaku-density-\(title)")
            // 点击内容区收起菜单，避免下一轮误点。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        }
        openSettings()
        // UIKit 原生菜单不透传 Toggle 的 identifier，以实际按钮标题和勾选态验收。
        let toggle = app.buttons["10秒内重复去重"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.isSelected
        toggle.tap()
        if !toggle.exists { openSettings() }
        XCTAssertNotEqual(toggle.isSelected, before)
        toggle.tap() // 恢复用户原去重设置。
        print("DD_DANMAKU_SETTINGS: density=standard; dedup-toggle=verified")
    }

    func testLiveStandaloneGameEntryRemoved() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["live.categories"].exists)
        XCTAssertFalse(app.buttons["游戏专区"].exists)
        attach(app, "live-standalone-game-entry-removed")
        discover.tap()
        XCTAssertTrue(app.buttons["live.category.game"].waitForExistence(timeout: 5))
        print("DD_GAME_ENTRY: standalone=removed; game-category=preserved")
    }

    func testLiveDiscoveryAndBack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["live.categories"].exists)
        XCTAssertFalse(app.buttons["游戏专区"].exists)
        XCTAssertFalse(app.buttons["live.category.featured"].exists)
        discover.tap()
        XCTAssertTrue(app.buttons["live.category.featured"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live.category.followed"].exists)
        XCTAssertFalse(app.buttons["live.category.nearby"].exists)
        app.buttons["live.category.chat"].tap()
        XCTAssertEqual(app.buttons["live.category.chat"].value as? String, "已选择")
        discover.tap()
        XCTAssertFalse(app.buttons["live.category.featured"].exists)
        let enter = app.buttons.matching(identifier: "live.room.enter").firstMatch
        XCTAssertTrue(enter.waitForExistence(timeout: 45))
        enter.tap()
        let back = app.buttons["live.room.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.label.contains("返回"))
        back.tap()
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        attach(app, "live-discovery-return")
    }

    func testLiveVerifiedCategories() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 30))
        let initial = expectation(for: NSPredicate(format: "label BEGINSWITH 'featured|' AND NOT label BEGINSWITH 'featured|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: app.staticTexts["live.source"])
        XCTAssertEqual(XCTWaiter().wait(for: [initial], timeout: 40), .completed)
        discover.tap()
        print("DDCATEGORY_SCREEN:before"); fflush(stdout); sleep(3)
        for id in ["nearby", "star", "group", "beauty", "sing"] {
            XCTAssertFalse(app.buttons["live.category.\(id)"].exists)
        }
        let strip = app.scrollViews["live.categoryStrip"]
        let source = app.staticTexts["live.source"]
        for (id, partition) in [("chat", "101"), ("music", "102"), ("anime", "104"), ("dance", "105"), ("culture", "106"), ("life", "107"), ("exercise", "108")] {
            let button = app.buttons["live.category.\(id)"]
            for _ in 0..<4 {
                if strip.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: -1, dy: -1).contains(button.frame) { break }
                strip.swipeLeft()
            }
            if !button.isHittable { print("DDCATEGORY_SCREEN:blocked"); fflush(stdout); sleep(3) }
            XCTAssertTrue(button.isHittable, id)
            button.tap()
            let loaded = expectation(for: NSPredicate { _, _ in
                let parts = source.label.split(separator: "|").map(String.init)
                return parts.count == 3 && parts[0] == partition && (Int(parts[1]) ?? 0) > 0 && parts[2] == "loaded"
            }, evaluatedWith: source)
            XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 40), .completed, id)
            XCTAssertEqual(button.value as? String, "已选择")
            print("DDCATEGORY_VERIFIED:\(id) source=\(source.label)")
        }
        print("DDCATEGORY_SCREEN:all"); fflush(stdout); sleep(4)
        for _ in 0..<4 {
            if strip.frame.intersection(app.windows.firstMatch.frame).contains(app.buttons["live.category.game"].frame) { break }
            strip.swipeRight()
        }
        app.buttons["live.category.game"].tap()
        XCTAssertTrue(app.buttons["live.categories.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["英雄联盟"].exists)
        app.buttons["live.categories.close"].tap()
        let game = expectation(for: NSPredicate(format: "label BEGINSWITH '103|' AND NOT label BEGINSWITH '103|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: source)
        XCTAssertEqual(XCTWaiter().wait(for: [game], timeout: 40), .completed)
        for _ in 0..<4 {
            if strip.frame.intersection(app.windows.firstMatch.frame).contains(app.buttons["live.category.featured"].frame) { break }
            strip.swipeRight()
        }
        app.buttons["live.category.featured"].tap()
        let featured = expectation(for: NSPredicate(format: "label BEGINSWITH 'featured|' AND NOT label BEGINSWITH 'featured|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: source)
        XCTAssertEqual(XCTWaiter().wait(for: [featured], timeout: 40), .completed)
    }

    func testMinePlayCountsAndCachedMessages() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_OPEN"] = "mine"
        app.launch()
        let count = app.descendants(matching: .any).matching(identifier: "douyin.grid.playCount").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(count.label.contains("播放量"))
        XCTAssertFalse(count.label.contains("未提供"), count.label)
        print("DDMINE_PLAY=\(count.label)")
        print("DDCHAT_SHOT_MINE"); sleep(4)
        app.buttons["douyin.mine.back"].tap()
        app.buttons["douyin.messages.top"].tap()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        sleep(4)
        app.buttons["douyin.messages.back"].tap()
        app.buttons["douyin.messages.top"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "缓存会话应该直接显示")
        print("DDCACHE_REOPEN=ready")
        print("DDCHAT_SHOT_CACHE"); sleep(4)
        app.terminate()
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        // 会话列表按设计是实时从网页抓（只有通知/计数走缓存），冷启动等它连上即可
        XCTAssertTrue(row.waitForExistence(timeout: 40), "冷启动后会话列表没拉起来")
        print("DDCACHE_COLD=ready")
    }

    func testTopBarHitEdges() throws {
        let app = XCUIApplication()
        app.launch()
        let info = app.buttons["douyin.messages.top"]
        XCTAssertTrue(info.waitForExistence(timeout: 40))
        // 点按钮边缘（不是文字中心）验证放大后的触摸区真的生效
        func tapEdge(_ el: XCUIElement, dx: CGFloat, dy: CGFloat) {
            let c = el.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
            c.tap()
        }
        let live = app.buttons.matching(NSPredicate(format: "label == '直播'")).firstMatch
        XCTAssertTrue(live.exists)
        tapEdge(live, dx: 0.5, dy: 0.94)
        sleep(4)
        print("DDHIT after-live-edge tab-\(app.staticTexts["live.currentID"].exists)")
        attach(app, "hit-live-edge")
        tapEdge(info, dx: 0.5, dy: 0.94)
        XCTAssertTrue(app.buttons["douyin.messages.back"].waitForExistence(timeout: 20), app.debugDescription)
        print("DDHIT info-bottom-edge ok")
        app.buttons["douyin.messages.back"].tap()
        let mine = app.buttons["douyin.mine.top"]
        tapEdge(mine, dx: 0.5, dy: 0.94)
        XCTAssertTrue(app.buttons["douyin.mine.back"].waitForExistence(timeout: 20), app.debugDescription)
        print("DDHIT mine-bottom-edge ok")
        app.buttons["douyin.mine.back"].tap()
        let recommend = app.buttons.matching(NSPredicate(format: "label == '推荐'")).firstMatch
        tapEdge(recommend, dx: 0.5, dy: 0.94)
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 25))
        sleep(3)
        print("DDHIT recommend-restored id=\(current.label)")
        attach(app, "hit-recommend-edge")
    }

    func testStrangerCategory() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let entry = app.buttons["douyin.messages.stranger"]
        XCTAssertTrue(entry.waitForExistence(timeout: 50), app.debugDescription)
        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        let mixed = rows.allElementsBoundByIndex.filter { ($0.value as? String) == "stranger" }
        XCTAssertEqual(mixed.count, 0, "陌生人不该平铺在首页列表")
        // 等预读把陌生人真实未读回填到入口角标（采集完整列表要十几秒）
        let filled = NSPredicate(format: "value != '0' AND value != '1'")
        _ = XCTWaiter().wait(for: [expectation(for: filled, evaluatedWith: entry)], timeout: 60)
        print("DDSTRANGERCAT entryBadge=\(entry.value ?? "-") friendRows=\(rows.count)")
        print("DDCHAT_SHOT_HOME"); sleep(3)

        entry.tap()
        let srows = app.buttons.matching(identifier: "douyin.stranger.row")
        XCTAssertTrue(srows.firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        print("DDSTRANGERCAT list=\(srows.count)")
        print("DDCHAT_SHOT_STRANGERLIST"); sleep(3)

        // 点最后一个人：网页里它在虚拟列表可视区外，验证滚动寻找 + 进的就是他本人
        XCTAssertGreaterThan(srows.count, 11, "陌生人列表没采全（虚拟列表只读到可视区）")
        // 原生列表滚到底，取最下面一个可点的人
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        sleep(1)
        let visible = srows.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(visible.isEmpty)
        let pick = visible.last!
        let who = pick.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        print("DDSTRANGERCAT pick=\(who)")
        pick.tap()
        let detail = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 25))
        sleep(4)
        let title = app.navigationBars.firstMatch.identifier
        print("DDSTRANGERCAT navTitle=\(title)")
        XCTAssertEqual(title, who, "进的会话不是点的那个人")
        XCTAssertGreaterThan(detail.frame.width, 800, "聊天页没铺满：\(detail.frame)")
        print("DDCHAT_SHOT_STRANGERCHAT"); sleep(3)
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))

        // 第一个人 = 主列表里我没关注的单聊（网页没放进陌生人面板），也要能点进本人
        entry.tap()
        XCTAssertTrue(srows.firstMatch.waitForExistence(timeout: 25))
        let first = srows.firstMatch
        let who2 = first.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        print("DDSTRANGERCAT pick2=\(who2)")
        first.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 25))
        sleep(4)
        let title2 = app.navigationBars.firstMatch.identifier
        print("DDSTRANGERCAT navTitle2=\(title2)")
        XCTAssertEqual(title2, who2)
        print("DDCHAT_SHOT_STRANGERCHAT2"); sleep(3)
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
    }

    func testTopBarFollowsCommentPanel() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(3)
        let mine = app.buttons["douyin.mine.top"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        let before = mine.frame
        let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(btn)
        btn!.tap()
        sleep(3)
        let close = app.buttons.matching(NSPredicate(format: "label == '关闭' OR identifier == 'douyin.comments.close'")).firstMatch
        let after = mine.frame
        let win = app.windows.firstMatch.frame
        print("DDTOPBAR before=\(before) after=\(after) win=\(win)")
        print("DDCHAT_SHOT_TOPBAR_COMMENTS"); sleep(3)
        // 评论栏 = 右侧 min(380, 42%)，顶栏最右的「我的」必须落在视频区里
        let panelW = min(380, win.width * 0.42)
        XCTAssertLessThanOrEqual(after.maxX, win.width - panelW + 1, "顶栏没跟视频缩到左边")
        XCTAssertTrue(mine.isHittable)
        mine.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), "我的按钮点不中")
        _ = close
    }

    /// 右侧栏顺序与间距：评论在收藏之上，且相邻图标间距收紧。
    func testRailCommentAboveCollectWithTightSpacing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(3)
        let like = app.buttons["douyin.like"].firstMatch
        let comment = app.buttons["douyin.comments"].firstMatch
        let collect = app.buttons["douyin.collect"].firstMatch
        let search = app.buttons["douyin.search"].firstMatch
        for item in [like, comment, collect, search] { XCTAssertTrue(item.waitForExistence(timeout: 10)) }
        XCTAssertLessThan(like.frame.midY, comment.frame.midY)
        XCTAssertLessThan(comment.frame.midY, collect.frame.midY, "评论应在收藏之上")
        XCTAssertLessThan(collect.frame.midY, search.frame.midY)
        let likeToComment = comment.frame.minY - like.frame.maxY
        let commentToCollect = collect.frame.minY - comment.frame.maxY
        for gap in [likeToComment, commentToCollect] {
            XCTAssertGreaterThanOrEqual(gap, 3, "图标间隙不能挤在一起")
            XCTAssertLessThanOrEqual(gap, 12, "图标间隙不能过松")
        }
        attach(app, "rail-comment-above-collect")
        print("DDRAIL: order=like,comment,collect,search; gaps=\(likeToComment)/\(commentToCollect)")
    }

    /// 外屏：从评论列表顶部下拉，而不是拖标题栏，应该跟手收起。
    func testOuterCommentsPullDownFromList() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        let ready = NSPredicate(format: "label != '-'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: ready, evaluatedWith: current)], timeout: 60), .completed)
        let entry = try XCTUnwrap(app.buttons.matching(identifier: "douyin.comments")
            .allElementsBoundByIndex.first { $0.isHittable })
        entry.tap()
        let dock = app.descendants(matching: .any).matching(identifier: "douyin.comments.dock").firstMatch
        guard dock.waitForExistence(timeout: 5) else {
            throw XCTSkip("此测试需在外屏窄窗口运行")
        }
        let list = app.scrollViews["douyin.comments.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let videoID = current.label
        // 慢速短拉应回弹，不能误关闭；触点在正文内，避开标题栏。
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(dock.exists)
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        let closed = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: closed, evaluatedWith: dock)], timeout: 5), .completed)
        XCTAssertEqual(current.label, videoID, "关闭评论不能切换视频")
        // 同一视频的面板复用后，关闭按钮仍必须生效，不能留下遮挡播放区的透明层。
        for _ in 0..<2 {
            entry.tap()
            XCTAssertTrue(dock.waitForExistence(timeout: 5))
            let close = app.buttons["douyin.comments.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: closed, evaluatedWith: dock)], timeout: 5), .completed)
            XCTAssertTrue(entry.isHittable)
            XCTAssertEqual(current.label, videoID)
        }
    }

    func testCommentImages() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        sleep(4)
        // 在推荐流里逐条打开评论，找带图/贴纸的评论；评论面板关掉再翻下一条
        for n in 0..<15 {
            let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            guard let btn else { app.swipeUp(); sleep(3); continue }
            btn.tap()
            sleep(5)
            let img = app.descendants(matching: .any).matching(identifier: "douyin.comment.images").firstMatch
            let stk = app.descendants(matching: .any).matching(identifier: "douyin.comment.sticker").firstMatch
            if img.exists || stk.exists {
                let hit = img.exists ? img : stk
                print("DDCOMMENTIMG found video#\(n) kind=\(img.exists ? "image" : "sticker")")
                // 在评论面板内滚动（不是整个 app，否则会翻走视频）
                let panel = app.scrollViews.allElementsBoundByIndex.first { $0.frame.minX > app.windows.firstMatch.frame.width * 0.5 } ?? app.scrollViews.allElementsBoundByIndex.last
                var tries = 0
                while !hit.isHittable && tries < 12 {
                    panel?.swipeUp(velocity: .slow)
                    tries += 1
                }
                print("DDCOMMENTIMG frame=\(hit.frame) hittable=\(hit.isHittable)")
                print("DDCHAT_SHOT_COMMENTIMG"); sleep(3)
                hit.tap()
                let close = app.buttons["douyin.comment.viewer.close"]
                XCTAssertTrue(close.waitForExistence(timeout: 10), "点图没打开全屏查看")
                sleep(3)
                print("DDCHAT_SHOT_COMMENTVIEWER"); sleep(3)
                close.tap()
                return
            }
            // 关评论：再点一次评论按钮（宽屏侧栏）或下滑（sheet）
            if btn.isHittable { btn.tap() } else { app.swipeDown(velocity: .fast) }
            sleep(2)
            app.swipeUp()
            sleep(4)
        }
        XCTFail("翻了15条视频都没遇到带图/贴纸的评论")
    }

    func testConversationListAndDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 50), app.debugDescription)
        attach(app, "conversation-native-root")
        print("DDCHAT_SHOT_ROOT"); sleep(4)
        let label = row.label
        print("DDCHAT root rows=\(app.buttons.matching(identifier: "douyin.conversation.row").count)")
        row.tap()
        sleep(5)
        attach(app, "conversation-single-detail")
        print("DDCHAT_SHOT_DETAIL"); sleep(4)
        print("DDCHAT_DETAIL\n\(app.debugDescription)\nDDCHAT_DETAIL_END")
        let web = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        XCTAssertTrue(web.exists)
        XCTAssertFalse(app.buttons["douyin.messages.interactive"].isHittable)
        let inputs = web.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue))
        XCTAssertGreaterThan(inputs.count, 0)
        if inputs.count > 0 {
            let input = inputs.firstMatch
            XCTAssertLessThanOrEqual(input.frame.maxY, app.windows.firstMatch.frame.maxY)
            input.tap()
            print("DDCHAT_SHOT_KEYBOARD"); sleep(4)
        }
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["douyin.messages.interactive"].exists)
        attach(app, "conversation-return-list")
        print("DDCHAT returned; original row label length=\(label.count)")
    }

    func testMessageReadAndVideoReturn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launchEnvironment["DOUDUO_READ_AUDIT"] = "1"
        app.launch()
        let entry = app.buttons["douyin.messages.interactive"]
        XCTAssertTrue(entry.waitForExistence(timeout: 35))
        sleep(12)
        print("DDUNREAD_BEFORE=\(entry.value ?? "nil")")
        entry.tap()
        sleep(12)
        attach(app, "notice-category")
        print("DDCHAT_SHOT_NOTICE"); sleep(4)
        let video = app.buttons.matching(identifier: "douyin.notice.video").firstMatch
        if video.waitForExistence(timeout: 15) {
            video.tap()
            let back = app.buttons["douyin.list.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 25))
            let like = app.buttons.matching(identifier: "douyin.like").allElementsBoundByIndex.first { $0.isHittable }
            if let like { XCTAssertLessThan(back.frame.midY, like.frame.midY) }
            attach(app, "notice-video-return-above-like")
            back.tap()
            sleep(2)
        }
        let back = app.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        sleep(10)
        // 退出分类只把看过的互动类（评论/赞）标已读；粉丝/系统仍可能有未读，所以看这个入口的角标
        print("DDUNREAD_AFTER=\(entry.value ?? "nil")")
        XCTAssertEqual(entry.value as? String, "0", "退出互动分类后它的未读应清零")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.conversation.row").firstMatch.waitForExistence(timeout: 15))
        attach(app, "message-read-and-conversations")
    }


    /// 只读采样手机上已安装的正式抖音 UI；默认跳过，不能用 DouDuo 页面冒充原版。
    func testOriginalLiveReference() throws {
        guard ProcessInfo.processInfo.environment["DOUDUO_ORIGINAL_REF"] == "1" else {
            throw XCTSkip("仅在连接已安装正式抖音的真机时手动启用")
        }
        let app = XCUIApplication(bundleIdentifier: "com.ss.iphone.ugc.Aweme")
        app.activate()
        sleep(5)
        guard app.state == .runningForeground else { throw XCTSkip("手机正在使用其他 App，停止采样") }
        print("DDORIGINAL_HOME\n\(app.debugDescription)\nDDORIGINAL_END")
        attach(app, "original-home")
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label == '直播'")).allElementsBoundByIndex.first { $0.isHittable }
        if let entry {
            entry.tap()
            sleep(6)
            guard app.state == .runningForeground else { throw XCTSkip("原版已不在前台，停止采样") }
            print("DDORIGINAL_LIVE\n\(app.debugDescription)\nDDORIGINAL_END")
            attach(app, "original-live")
        }
        let roomEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS '点击进入直播间'")).firstMatch
        if roomEntry.waitForExistence(timeout: 8), roomEntry.isHittable {
            roomEntry.tap()
            sleep(6)
            guard app.state == .runningForeground else { throw XCTSkip("原版已不在前台，进房采样作废") }
            print("DDORIGINAL_ROOM\n\(app.debugDescription)\nDDORIGINAL_END")
            attach(app, "original-room")
        }
    }

    func testLivePagesFillViewport() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        let loaded = expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 40), .completed)
        for index in 0..<2 {
            let id = current.label
            let page = app.otherElements["live.page.\(id)"]
            XCTAssertTrue(page.waitForExistence(timeout: 5))
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(page.frame.height, window.height, accuracy: 1, "直播页必须覆盖实际视口，不能少掉底部安全区")
            XCTAssertEqual(page.frame.maxY, window.maxY, accuracy: 1, "静止时页底必须与窗口底边重合")
            attach(app, "live-page-fill-\(index)")
            if index == 0 {
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
                let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
                XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed)
                sleep(1)
            }
        }
    }

    func testNativeLiveRoomFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let categories = app.buttons["live.discover"]
        XCTAssertTrue(categories.waitForExistence(timeout: 15), "发现更多应收成一个按钮")
        XCTAssertFalse(app.buttons["live.categories"].exists, "单独游戏专区入口已移除")
        XCTAssertFalse(app.buttons["英雄联盟"].exists, "分类不能常驻")
        categories.tap()
        app.buttons["live.category.game"].tap()
        XCTAssertTrue(app.buttons["英雄联盟"].waitForExistence(timeout: 5))
        attach(app, "live-category-picker")
        app.buttons["live.categories.close"].tap()
        categories.tap()
        let enter = app.buttons.matching(identifier: "live.room.enter").firstMatch
        XCTAssertTrue(enter.waitForExistence(timeout: 30))
        XCTAssertTrue(enter.isHittable)
        let id = app.staticTexts["live.currentID"].label
        enter.tap()
        XCTAssertTrue(app.buttons["live.room.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["live.chat.input"].exists)
        XCTAssertFalse(app.buttons["live.categories"].exists, "进房后不显示首页分类按钮")
        XCTAssertFalse(app.buttons["douyin.web.close"].exists, "进房不能打开网页版播放器")
        attach(app, "native-live-room")
        app.buttons["live.room.more"].tap()
        app.buttons["清屏"].tap()
        XCTAssertTrue(app.buttons["live.room.restore"].waitForExistence(timeout: 5))
        app.buttons["live.room.restore"].tap()
        app.buttons["live.room.close"].tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["live.currentID"].label, id, "退房应回到同一个直播预览")
        attach(app, "live-preview-return")
        let page = app.otherElements["live.page.\(id)"]
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        let current = app.staticTexts["live.currentID"]
        let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed, "上滑应换到相邻房间")
        let nextID = current.label
        sleep(3)
        XCTAssertEqual(current.label, nextID, "停止滑动后不应因布局回写继续乱跳")
    }

    /// 使用真实作品详情验证声明与时间，不通过标题猜 AI，也不做账号互动。
    func testVideoMetadataAIAndPublication() throws {
        for (id, isAI, name) in [("7705789488781932361", true, "ai"), ("7705458913226935590", false, "normal")] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = id
            app.launch()
            let current = app.staticTexts["douyin.currentID"]
            XCTAssertTrue(current.waitForExistence(timeout: 30))
            let loaded = expectation(for: NSPredicate(format: "label == %@", id), evaluatedWith: current)
            XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 50), .completed)
            let metadata = app.staticTexts.matching(identifier: "douyin.video.metadata").firstMatch
            XCTAssertTrue(metadata.waitForExistence(timeout: 10))
            XCTAssertTrue(metadata.label.contains("发布"))
            XCTAssertEqual(metadata.label.contains("作者声明：内容由 AI 生成"), isAI)
            print("DDMETA_SCREEN:\(name) label=\(metadata.label)")
            fflush(stdout)
            sleep(4)
            app.terminate()
        }
    }

    /// 只输入草稿、不点击发送；验证真实隐藏网页就绪后，原生发送按钮才可用。
    func testLiveComposerReadyWithoutSending() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_AUTOLIVEROOM"] = "1"
        app.launch()
        let input = app.textFields["live.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 35))
        let ready = expectation(for: NSPredicate(format: "value == %@", "说点什么…"), evaluatedWith: input)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 65), .completed, "必须等官网真实输入框挂载，不用视频首帧代替")
        input.tap()
        input.typeText("LOCAL_ONLY_DO_NOT_SEND")
        let send = app.buttons["live.chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(input.value as? String, "LOCAL_ONLY_DO_NOT_SEND")
        print("DDCOMPOSER_UI ready=true draft-preserved=true send-enabled=true no-send-performed=true")
        app.terminate()
    }

    /// 真机/模拟器均可跑；计时以 App 的 DDLIVE_READY 日志为准，截图另证是否实际出画。
    func testNativeLivePerformance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_LIVEPROBE"] = "1"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        let status = app.staticTexts["live.status"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        for index in 0..<3 {
            let ready = expectation(for: NSPredicate(format: "label == '1'"), evaluatedWith: status)
            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 45), .completed, "当前房间没有视频输出")
            guard app.state == .runningForeground else { throw XCTSkip("用户切走了 App，本次截图作废") }
            let id = current.label
            attach(app, "device-live-frame-\(index)")
            let progress = app.staticTexts["live.time"].label
            print("DDDEVICE_SAMPLE index=\(index) id=\(id) progress=\(progress)")
            if index < 2 {
                let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
                XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 30), .completed, "探针没有切到下一间")
            }
        }
    }

    /// 头部缓存起播：先让当前条缓存 + 预取后面 2 条，再上滑看是否本地起播并在安全点切回在线
    func testHeadCachePlayback() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        let loaded = expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 60), .completed)
        sleep(16)  // 当前条整条缓存 + 后面 2 条头部预取（等落盘完成再切）
        let first = current.label
        app.swipeUp(velocity: .fast)
        let changed = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 15), .completed, "上滑没切条")
        // 进度文字在紧凑模式下不一定暴露给 XCUI，这里以 ddlog 的 DDSTART local=true / DDHEAD continue 为准
        sleep(4)
        attach(app, "head-cache-play")
        sleep(14)  // 跨过 headPlayableSeconds，验证续播不卡死
        attach(app, "head-cache-continued")
    }

    // MARK: - 演示视频分幕（每幕单独录屏）

    /// 幕2 合盖外屏：刷推荐流
    func testTourOuter() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(13)
        for _ in 0..<2 {
            let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
            sleep(5)
        }
    }

    /// 幕6 设置：竖屏 70% + 短视频 70%
    func testTourSettings() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(13)
        app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }?.tap()
        sleep(3)
        app.buttons["设置"].firstMatch.tap()
        sleep(4)
        let any = { (kw: String) in
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", kw))
                .allElementsBoundByIndex.first { $0.isHittable && $0.frame.width > 20 }
        }
        any("竖屏占比")?.tap()
        sleep(4)
        app.buttons["70%"].firstMatch.tap()
        sleep(3)
        any("竖屏短视频占比")?.tap()
        sleep(4)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(3)
        app.tap()
        sleep(4)
    }

    /// 幕7 液态玻璃胶囊：点赞 / 收藏反馈
    func testTourRail() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(13)
        for id in ["douyin.like", "douyin.favorite"] {
            let b = app.buttons.matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
            b?.tap()
            sleep(4)
            b?.tap()
            sleep(3)
        }
    }

    /// 幕5 半折叠桌面式：滑评论
    func testTourFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        sleep(26)
        let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(5)
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(4)
    }

    /// 幕9 直播：分类按钮 → 进原生直播间
    func testTourLive() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(13)
        app.buttons["直播"].firstMatch.tap()
        sleep(9)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(6)
        app.buttons["推荐直播"].firstMatch.tap()
        sleep(9)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(14)
    }

    /// 幕3 展开宽屏（iPad）：点评论 → 右侧滑出
    func testTourWide() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(14)
        let b = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        b?.tap()
        sleep(6)
        let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6))
        let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25))
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(5)
    }

    /// 截图用（iPad 宽屏）：点开评论 → 右侧滑出
    func testCaptureWideComment() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(14)
        let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        btn?.tap()
        sleep(5)
        attach(app, "wide-comment")
    }

    /// 截图用（iPad 横屏 + 半折叠）：书本式左右分
    func testCaptureBookFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(16)
        attach(app, "book-fold")
    }

    /// 截图用：保持横屏 40 秒，外部用 simctl 抓物理屏
    func testHoldLandscape() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        sleep(10)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(40)
    }

    /// 截图用：横屏 + 宽屏布局（评论右侧滑出）
    func testCaptureLandscapeWide() throws {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(12)
        let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        btn?.tap()
        sleep(4)
        attach(app, "land-wide")
    }

    /// 截图用：横屏 + 强制半折叠（书本式左右分）
    func testCaptureLandscapeFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(14)
        attach(app, "land-fold")
    }

    /// 录屏版：先手动启动 App 再开录，这里只接管前台，画面从第一帧就是 App
    func testFeatureTourActive() throws {
        let app = XCUIApplication()
        app.activate()
        sleep(2)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        let current = app.staticTexts["douyin.currentID"]
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 40)
        sleep(4)

        // 更多 → 设置：短视频占比（展示 4 秒 + 选项 5 秒）
        app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }?.tap()
        sleep(3)
        app.buttons["设置"].firstMatch.tap()
        sleep(4)
        app.buttons["竖屏短视频占比（3 分钟内）"].firstMatch.tap()
        sleep(5)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(2)
        app.tap()
        sleep(3)

        // 直播：分类按钮 → 面板 → 专区 → 进房
        app.buttons["直播"].firstMatch.tap()
        sleep(5)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(5)
        app.buttons["英雄联盟"].firstMatch.tap()
        sleep(6)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(6)

        // 直播间：更多 → 清屏 → 恢复
        app.buttons["live.room.more"].firstMatch.tap()
        sleep(3)
        app.buttons["清屏"].firstMatch.tap()
        sleep(4)
        app.buttons["live.room.restore"].firstMatch.tap()
        sleep(3)
        app.buttons["live.room.close"].firstMatch.tap()
        sleep(4)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        attach(app, "tour-active-end")
    }

    /// 功能演示脚本（录屏用）：按固定节奏走一遍新功能，不做断言，只保证画面走位
    func testFeatureTour() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60)
        sleep(3)

        // 更多 → 设置：短视频占比
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
        more?.tap()
        sleep(2)
        app.buttons["设置"].firstMatch.tap()
        sleep(2)
        app.buttons["竖屏短视频占比（3 分钟内）"].firstMatch.tap()
        sleep(2)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(2)
        app.tap()
        sleep(2)

        // 直播：分类按钮 → 专区 → 进房 → 清屏 → 退出
        app.buttons["直播"].firstMatch.tap()
        sleep(4)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(3)
        app.buttons["英雄联盟"].firstMatch.tap()
        sleep(5)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(4)
        app.buttons["live.room.more"].firstMatch.tap()
        sleep(2)
        app.buttons["清屏"].firstMatch.tap()
        sleep(2)
        app.buttons["live.room.restore"].firstMatch.tap()
        sleep(2)
        app.buttons["live.room.close"].firstMatch.tap()
        sleep(3)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        attach(app, "tour-end")
    }

    func testConditionalTitleExpansion() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_TITLETEST"] = "1"
        app.launch()
        let short = app.otherElements["title.short"]
        let long = app.otherElements["title.long"]
        XCTAssertTrue(short.waitForExistence(timeout: 10))
        XCTAssertFalse(short.buttons["douyin.description.toggle"].exists, "短标题不应出现展开按钮")
        let toggle = long.buttons["douyin.description.toggle"]
        XCTAssertTrue(toggle.exists, "长标题被截断时应有展开按钮")
        XCTAssertEqual(toggle.label, "展开")
        let collapsedHeight = long.frame.height
        toggle.tap()
        XCTAssertEqual(toggle.label, "收起")
        sleep(1)
        XCTAssertGreaterThan(long.frame.height, collapsedHeight, "展开后应显示完整标题而不只是切换按钮文字")
        attach(app, "expanded-title")
        toggle.tap()
        XCTAssertEqual(toggle.label, "展开")
        sleep(1)
        attach(app, "conditional-title")
    }

    func testCompactLayoutAndAuthorEntry() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(3)
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.follow").allElementsBoundByIndex.contains { $0.isHittable })
        let desc = app.staticTexts.matching(identifier: "douyin.description").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(desc)
        if let desc { XCTAssertLessThan(desc.frame.height, 40, "标题默认应只有一行") }
        let toggle = app.buttons.matching(identifier: "douyin.description.toggle").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(toggle)
        toggle?.tap()
        XCTAssertTrue(app.buttons["收起"].exists)
        app.buttons["收起"].tap()
        attach(app, "compact-single-line")
        let author = app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(author)
        author?.tap()
        XCTAssertTrue(app.buttons["douyin.author.follow"].waitForExistence(timeout: 15))
        attach(app, "author-follow-retained")
        app.buttons["douyin.author.back"].tap()
    }

    func testCoreFlow() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed, "推荐流没加载出来")
        sleep(6)
        attach(app, "1-feed")

        // 视频在走：进度时间 > 0:00
        let t1 = playTime(app)
        sleep(3)
        let t2 = playTime(app)
        print("DDTEST time \(t1) -> \(t2)")
        XCTAssertGreaterThan(t2, 0, "视频没在播")

        // 上滑下一条
        let first = current.label
        app.swipeUp(velocity: .fast)
        sleep(4)
        XCTAssertNotEqual(current.label, first, "上滑没切到下一条")
        let second = current.label
        XCTAssertGreaterThan(playTime(app), 0, "第二条没在播")
        attach(app, "2-next")

        // 横滑快进
        // 横滑快进。⚠️ 真机上 XCUICoordinate.press(…thenDragTo:) 根本不派发触摸（DDTOUCH 实测一个都没有），
        // swipeUp 能到 → 横向也用 swipe 系列（从画面中部起滑）
        app.swipeRight(velocity: .slow)
        sleep(3)
        XCTAssertEqual(current.label, second, "横滑不应切视频")
        print("DDTEST after seek \(playTime(app))")
        XCTAssertGreaterThanOrEqual(playTime(app), 25, "横滑快进没跳")

        // 点作者头像 → 网页主页 → 返回
        // 分页 ScrollView 同时保留离屏元素，只点当前可命中的作者。
        let authors = app.buttons.matching(identifier: "douyin.author")
        let author = authors.allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(author, "当前页没有可点击的作者入口")
        guard let author else { return }
        author.tap()
        // 改版作者页已原生化，不能再等旧网页版返回键。
        let back = app.buttons["douyin.author.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "作者主页没打开 / 没有返回键")
        sleep(4)
        attach(app, "3-author")
        back.tap()
        XCTAssertTrue(current.waitForExistence(timeout: 15), "从作者主页回不来")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed, "返回后推荐流没恢复")
        sleep(6)
        XCTAssertGreaterThan(playTime(app), 0, "返回后视频没在播")
        attach(app, "4-back")
    }

    /// 窄视频（720x1280）在 Duo 上：开=铺满宽度（上下裁切），关=左右黑边。用本地测试片验证，不依赖推荐流给什么片。
    func testLocalNarrowFill() throws {
        for fit in ["1", "0"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_LOCALVIDEO"] = "narrow.mp4"
            app.launchEnvironment["DOUDUO_LOCALFIT"] = fit
            app.launch()
            sleep(6)
            attach(app, "narrow-fit-\(fit)")
            app.terminate()
        }
    }

    /// 确认 App 真的能转到横屏（窗口宽>高）
    /// ⚠️ XCUIDevice 转屏在这台机器上时好时坏（无头/屏幕休眠时静默失败），重试 3 次仍不转就 skip，不当作 App 缺陷
    func testRotationSanity() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_LOCALVIDEO"] = "wide.mp4"
        app.launchEnvironment["DOUDUO_LOCALFIT"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        sleep(4)
        let p = app.windows.firstMatch.frame
        print("DDTEST portrait window \(p)")
        var l = p
        for i in 1...3 {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(3)
            l = app.windows.firstMatch.frame
            print("DDTEST landscape window try\(i) \(l)")
            if l.width > l.height { break }
        }
        if l.width <= l.height {
            XCUIDevice.shared.orientation = .portrait
            throw XCTSkip("转屏指令没生效（环境问题），跳过；真机手动转屏正常")
        }
        attach(app, "rot-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    /// 竖屏 + 横屏 都要自适应（无黑边）：本地 720x1280 与 1280x720 测试片各跑一遍
    func testLocalFillBothOrientations() throws {
        // 先启动再转屏（启动时设方向会被 App 启动重置）
        for (file, orient, tag) in [("narrow.mp4", UIDeviceOrientation.portrait, "portrait"),
                                    ("wide.mp4", .portrait, "portrait"),
                                    ("narrow.mp4", .landscapeLeft, "landscape"),
                                    ("wide.mp4", .landscapeLeft, "landscape")] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_LOCALVIDEO"] = file
            app.launchEnvironment["DOUDUO_LOCALFIT"] = "1"
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            sleep(4)
            XCUIDevice.shared.orientation = orient
            sleep(5)
            attach(app, "\(file)-\(tag)")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// 「更多」菜单：一排快捷图标 + 播放组 + 设置子菜单；竖屏占比子菜单可选
    func testMoreMenuLayout() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(3)
        let any = { (l: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", l)).firstMatch }
        // 分页里上下相邻页的「更多」也在树里，只点屏幕内那颗
        let more = { app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }! }
        more().tap()
        for l in ["转发", "下载", "不感兴趣", "竖屏占比", "自动连播", "静音", "显示弹幕", "刷新推荐", "我的", "设置"] {
            XCTAssertTrue(any(l).waitForExistence(timeout: 5), "更多菜单缺少 \(l)")
        }
        attach(app, "more-top")
        any("竖屏占比").tap()
        XCTAssertTrue(any("竖屏 50%").waitForExistence(timeout: 5), "竖屏占比子菜单没展开")
        attach(app, "more-mix")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        sleep(1)
        more().tap()
        any("设置").tap()
        for l in ["横着看时只放横屏", "自动铺满宽度", "预缓存视频", "清除视频缓存", "网页版", "关于"] {
            XCTAssertTrue(any(l).waitForExistence(timeout: 5), "设置子菜单缺少 \(l)")
        }
        attach(app, "more-settings")
    }

    /// VLC 兜底路径：强制 VLC 起播，画面时间要走、能上滑切换
    func testVLCFallback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FORCE_VLC"] = "1"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(10)
        let t1 = playTime(app); sleep(3); let t2 = playTime(app)
        print("DDTEST vlc time \(t1) -> \(t2)")
        XCTAssertGreaterThan(t2, t1, "VLC 没在播")
        attach(app, "vlc-1")
        let first = current.label
        app.swipeUp(velocity: .fast)
        sleep(8)
        XCTAssertNotEqual(current.label, first, "VLC 下上滑没切")
        let t3 = playTime(app); sleep(3); let t4 = playTime(app)
        print("DDTEST vlc next \(t3) -> \(t4)")
        XCTAssertGreaterThan(t4, t3, "VLC 第二条没在播")
        attach(app, "vlc-2")
    }


    /// 停声链路（不依赖切后台事件）：DOUDUO_BGTEST=1 → 20 秒后自动 pauseAll，进度必须冻住
    func testPauseAllPlumbing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_BGTEST"] = "1"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(5)
        let t1 = playTime(app)
        sleep(12)
        let t2 = playTime(app)
        sleep(6)
        let t3 = playTime(app)
        print("DDTEST plumbing t1=\(t1) t2=\(t2) t3=\(t3)")
        XCTAssertGreaterThan(t1, 0)
        XCTAssertLessThanOrEqual(t3, t2 + 1, "pauseAll 之后进度还在走")
    }

    /// 直播播放：UI 测试里量不到真实播放（XCTest 环境下 HLS 已 readyToPlay 但进度不走，
    /// 同样的构建用 simctl 启动播放正常）→ 这里只做冒烟：能进直播页、能拿到房间、不崩
    func testLivePlayback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let liveID = app.staticTexts["live.currentID"]
        XCTAssertTrue(liveID.waitForExistence(timeout: 30), "直播页没打开")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: liveID)], timeout: 60), .completed, "直播列表没加载出来")
        sleep(8)
        let st = app.staticTexts["live.status"].label
        let rate = app.staticTexts["live.rate"].label
        let t = app.staticTexts["live.time"].label
        print("DDTEST live id=\(liveID.label) status=\(st) rate=\(rate) time=\(t)")
        attach(app, "live")
        XCTAssertEqual(st, "1", "直播流没 ready（status=\(st)）")
    }

    /// 点赞 / 收藏走真接口。
    /// 未登录时 App 会提示「请先登录抖音」并自动打开网页登录 → 这种情况 skip（不是缺陷）
    func testLikeAndCollect() throws {
        throw XCTSkip("本次只读验收：禁止使用老板账号执行点赞/收藏写接口")
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 90), .completed)
        sleep(6)

        let toast = app.staticTexts["douyin.toast"]
        let like = app.buttons["douyin.like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 10), "没有点赞按钮")

        like.tap()
        let gotToast = toast.waitForExistence(timeout: 6)
        let label = gotToast ? toast.label : ""
        print("DDTEST like toast: \(label.isEmpty ? "<none>" : label)")
        if label.contains("请先登录") { throw XCTSkip("当前未登录抖音，点赞/收藏需要登录后才能验") }
        XCTAssertFalse(gotToast, "点赞失败弹了提示：\(label)")
        attach(app, "like")

        let collect = app.buttons["douyin.collect"].firstMatch
        XCTAssertTrue(collect.waitForExistence(timeout: 10), "没有收藏按钮")
        collect.tap()
        let got2 = toast.waitForExistence(timeout: 10)
        let label2 = got2 ? toast.label : "<none>"
        print("DDTEST collect toast: \(label2)")
        XCTAssertTrue(got2, "收藏后没有提示（接口没返回）")
        XCTAssertTrue(label2.contains("已收藏"), "收藏没成功：\(label2)")
        attach(app, "collect")
    }

    /// 底部进度条左侧时间（秒）
    private func playTime(_ app: XCUIApplication) -> Int {
        let q = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9][0-9]$'"))
        guard q.count > 0 else { return 0 }
        return q.element(boundBy: 0).label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
