import SwiftTreeSitter

public extension ASTTree {
    /// Dumps the syntax tree as a string, for debugging purposes.
    func dump() -> String {
        guard let tree, let root = tree.rootNode else { return "" }
        var result = ""

        let appendNode: (_ level: Int, _ node: Node) -> Void = { level, node in
            let line =
                "\(String(repeating: "  ", count: level))\(node.nodeType ?? "N/A") \(node.pointRange)"
            result += line + "\n"
        }

        guard let node = root.descendant(in: root.byteRange) else { return result }

        appendNode(0, node)

        let cursor = node.treeCursor
        let level = 1

        if cursor.goToFirstChild(for: node.byteRange.lowerBound) == false {
            return result
        }

        cursor.enumerateCurrentAndDescendents(level: level + 1) { level, node in
            appendNode(level, node)
        }

        while cursor.gotoNextSibling() {
            guard let node = cursor.currentNode else {
                assertionFailure("no current node when gotoNextSibling succeeded")
                break
            }

            // once we are past the interesting range, stop
            if node.byteRange.lowerBound > root.byteRange.upperBound {
                break
            }

            cursor.enumerateCurrentAndDescendents(level: level + 1) { level, node in
                appendNode(level, node)
            }
        }

        return result
    }
}

private extension TreeCursor {
    func enumerateCurrentAndDescendents(level: Int, block: (Int, Node) throws -> Void) rethrows {
        if let node = currentNode {
            try block(level, node)
        }

        if goToFirstChild() == false {
            return
        }

        try enumerateCurrentAndDescendents(level: level + 1, block: block)

        while gotoNextSibling() {
            try enumerateCurrentAndDescendents(level: level + 1, block: block)
        }

        let success = gotoParent()

        assert(success)
    }
}
