import Foundation

extension FileTree {
  /// Live, non-empty children, largest first; ties break by index so every
  /// layout built from the same tree orders siblings identically.
  public func orderedChildren(_ id: NodeID) -> [NodeID] {
    var result: [NodeID] = []
    let range = children(id)
    result.reserveCapacity(range.count)
    for child in range where !isRemoved(child) && sizes[Int(child)] > 0 {
      result.append(child)
    }
    result.sort { a, b in
      let sa = sizes[Int(a)]
      let sb = sizes[Int(b)]
      return sa != sb ? sa > sb : a < b
    }
    return result
  }

  /// The `limit` largest live children in one linear pass (no full sort),
  /// so huge directories stay cheap to inspect on hover.
  public func largestChildren(_ id: NodeID, limit: Int) -> [NodeID] {
    guard limit > 0 else { return [] }
    var top: [NodeID] = []
    top.reserveCapacity(limit + 1)
    func before(_ a: NodeID, _ b: NodeID) -> Bool {
      let sa = sizes[Int(a)]
      let sb = sizes[Int(b)]
      return sa != sb ? sa > sb : a < b
    }
    for child in children(id) where !isRemoved(child) && sizes[Int(child)] > 0 {
      if top.count == limit, let last = top.last, !before(child, last) { continue }
      let index = top.firstIndex { before(child, $0) } ?? top.count
      top.insert(child, at: index)
      if top.count > limit { top.removeLast() }
    }
    return top
  }

  /// Whether `id` lies inside `ancestor`'s subtree (or is it).
  public func isDescendant(_ id: NodeID, of ancestor: NodeID) -> Bool {
    var cur: NodeID? = id
    while let c = cur {
      if c == ancestor { return true }
      if c < ancestor { return false }
      cur = parent(c)
    }
    return false
  }
}
