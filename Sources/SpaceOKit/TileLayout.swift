import Foundation
import CoreGraphics

/// How a shared agent display is divided between sessions.
///
/// Creating a virtual display is not free — it is a whole framebuffer the WindowServer has to
/// composite — so several agents share one. Each gets a tile, and every tile is a real region
/// of a genuinely visible display, which is what preserves the property the whole design rests
/// on: windows there keep rendering.
///
/// Pure geometry, so the packing rules are testable without touching the WindowServer.
public enum TileLayout {

    /// Column/row split for a given capacity. Wider than tall, because app windows are.
    public static func grid(for capacity: Int) -> (columns: Int, rows: Int) {
        let n = max(1, capacity)
        switch n {
        case 1:      return (1, 1)
        case 2:      return (2, 1)
        case 3, 4:   return (2, 2)
        case 5, 6:   return (3, 2)
        case 7...9:  return (3, 3)
        case 10...12: return (4, 3)
        default:
            let columns = Int(ceil(sqrt(Double(n))))
            let rows = Int(ceil(Double(n) / Double(columns)))
            return (columns, rows)
        }
    }

    /// The tile rects for `capacity` sessions inside `bounds`, in row-major order.
    ///
    /// Tiles tile the display exactly — no gutters. A gutter would waste pixels an agent could
    /// be reading, and nothing here needs to look pretty to a human.
    public static func rects(in bounds: CGRect, capacity: Int) -> [CGRect] {
        guard capacity > 0 else { return [] }
        let n = capacity
        let (columns, rows) = grid(for: n)
        let tileWidth = (bounds.width / CGFloat(columns)).rounded(.down)
        let tileHeight = (bounds.height / CGFloat(rows)).rounded(.down)

        var out: [CGRect] = []
        out.reserveCapacity(n)
        for index in 0..<n {
            let column = index % columns
            let row = index / columns
            out.append(CGRect(x: bounds.minX + CGFloat(column) * tileWidth,
                              y: bounds.minY + CGFloat(row) * tileHeight,
                              width: tileWidth,
                              height: tileHeight))
        }
        return out
    }

    /// The tile at `index`, or nil when the index is outside the capacity.
    public static func rect(in bounds: CGRect, capacity: Int, index: Int) -> CGRect? {
        guard capacity > 0, index >= 0, index < capacity else { return nil }
        let (columns, rows) = grid(for: capacity)
        let tileWidth = (bounds.width / CGFloat(columns)).rounded(.down)
        let tileHeight = (bounds.height / CGFloat(rows)).rounded(.down)
        let column = index % columns
        let row = index / columns
        return CGRect(x: bounds.minX + CGFloat(column) * tileWidth,
                      y: bounds.minY + CGFloat(row) * tileHeight,
                      width: tileWidth,
                      height: tileHeight)
    }

    /// A display size that gives `capacity` sessions a comfortable tile each.
    ///
    /// Virtual displays cost nothing to make bigger — they are not real panels — so the sane
    /// answer to "I want four agents" is a larger canvas, not a refusal. Only a size the user
    /// pinned themselves should ever produce a refusal.
    public static func displaySize(forCapacity capacity: Int,
                                   tile: CGSize = CGSize(width: 1280, height: 800)) -> CGSize {
        let (columns, rows) = grid(for: capacity)
        return CGSize(width: tile.width * CGFloat(columns),
                      height: tile.height * CGFloat(rows))
    }

}
