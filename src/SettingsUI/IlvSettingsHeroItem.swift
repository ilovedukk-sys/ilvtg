// ilvtg — the header of the ilvtg settings screen: app icon, name and version.
// Copied into submodules/SettingsUI/Sources/Ilv/ by ci/prepare.py.

import Foundation
import UIKit
import Display
import SwiftSignalKit
import ItemListUI

/// Large app icon: the white ghost on a cherry rounded square.
func ilvLargeAppIcon(size: CGFloat) -> UIImage {
    let canvas = CGSize(width: size, height: size)
    return UIGraphicsImageRenderer(size: canvas).image { _ in
        let rect = CGRect(origin: .zero, size: canvas)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.225)
        path.addClip()
        let colors = [UIColor(red: 0.80, green: 0.13, blue: 0.30, alpha: 1.0).cgColor, UIColor(red: 0.45, green: 0.04, blue: 0.16, alpha: 1.0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
            UIGraphicsGetCurrentContext()?.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: size, y: size), options: [])
        }
        let ghostSize = size * 0.62
        ilvGhostImage(color: .white, size: ghostSize, crossed: false).draw(in: CGRect(x: (size - ghostSize) / 2.0, y: (size - ghostSize) / 2.0 + size * 0.02, width: ghostSize, height: ghostSize))
    }
}

final class IlvSettingsHeroItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let title: String
    let subtitle: String
    let sectionId: ItemListSectionId

    var isAlwaysPlain: Bool {
        return true
    }

    init(presentationData: ItemListPresentationData, title: String, subtitle: String, sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.title = title
        self.subtitle = subtitle
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = IlvSettingsHeroItemNode()
            let layout = node.update(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, {
                return (nil, { _ in })
            })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? IlvSettingsHeroItemNode else {
                return
            }
            let layout = node.update(item: self, params: params)
            completion(layout, { _ in })
        }
    }
}

private final class IlvSettingsHeroItemNode: ListViewItemNode {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init() {
        super.init(layerBacked: false)
        self.iconView.image = ilvLargeAppIcon(size: 96.0)
        self.iconView.layer.shadowColor = UIColor.black.cgColor
        self.iconView.layer.shadowOpacity = 0.25
        self.iconView.layer.shadowRadius = 10.0
        self.iconView.layer.shadowOffset = CGSize(width: 0.0, height: 4.0)
        self.titleLabel.font = .systemFont(ofSize: 28.0, weight: .bold)
        self.titleLabel.textAlignment = .center
        self.subtitleLabel.font = .systemFont(ofSize: 17.0, weight: .regular)
        self.subtitleLabel.textAlignment = .center
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.iconView)
        self.view.addSubview(self.titleLabel)
        self.view.addSubview(self.subtitleLabel)
    }

    func update(item: IlvSettingsHeroItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        let theme = item.presentationData.theme
        self.titleLabel.text = item.title
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.subtitleLabel.text = item.subtitle
        self.subtitleLabel.textColor = theme.list.itemSecondaryTextColor

        let width = params.width
        let iconSize: CGFloat = 96.0
        let top: CGFloat = 16.0
        self.iconView.frame = CGRect(x: floor((width - iconSize) / 2.0), y: top, width: iconSize, height: iconSize)
        self.titleLabel.frame = CGRect(x: params.leftInset + 16.0, y: top + iconSize + 14.0, width: max(1.0, width - params.leftInset - params.rightInset - 32.0), height: 34.0)
        self.subtitleLabel.frame = CGRect(x: params.leftInset + 16.0, y: self.titleLabel.frame.maxY + 2.0, width: self.titleLabel.frame.width, height: 22.0)
        let height = self.subtitleLabel.frame.maxY + 18.0
        return ListViewItemNodeLayout(contentSize: CGSize(width: width, height: height), insets: UIEdgeInsets())
    }
}
