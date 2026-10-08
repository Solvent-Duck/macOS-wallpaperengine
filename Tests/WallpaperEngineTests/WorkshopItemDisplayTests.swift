import Foundation
import SteamLibrary
import Testing
@testable import WallpaperEngine

struct WorkshopItemDisplayTests {
    @Test func stripsBBCodeAndFormatsApproval() {
        let item = WorkshopItem(id: "1", title: "T",
                                description: "[h1]Rain[/h1]\n[url=https://x]Link[/url] [b]bold[/b] [list][*]one[/list]",
                                votesUp: 95, votesDown: 5)
        #expect(item.plainDescription == "Rain\nLink bold one")
        #expect(item.approvalText == "95%")
        #expect(WorkshopItem(id: "2", title: "T", votesUp: 3, votesDown: 0).approvalText == nil)
    }
}
