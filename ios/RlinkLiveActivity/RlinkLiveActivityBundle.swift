import SwiftUI
import WidgetKit

@main
struct RlinkLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            RlinkLiveActivityWidget()
        }
    }
}
