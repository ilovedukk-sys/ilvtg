// ilvtg — tab bar settings. Copied into submodules/TelegramUI/Sources/Ilv/ by ci/prepare.py.
// TelegramRootController calls ilvRefreshTabs when a tab setting changes (edit "tabs-observe").

import Foundation
import Display
import TabBarUI

extension TelegramRootController {
    func ilvRefreshTabs() {
        guard let rootTabController = self.rootTabController as? TabBarControllerImpl else {
            return
        }
        let controllers = rootTabController.controllers
        let showCallsTab = controllers.contains(where: { $0 === self.callListController })
        let showNewsTab = controllers.contains(where: { $0 === self.newsController })
        self.updateRootControllers(showCallsTab: showCallsTab, showNewsTab: showNewsTab)
    }
}
