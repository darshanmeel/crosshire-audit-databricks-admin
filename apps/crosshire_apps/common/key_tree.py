"""Describe a JSON value by its key names, types and list lengths only; never its values."""


def _merge(tree, value):
    if isinstance(value, dict):
        node = tree.setdefault("object", {})
        for k, v in value.items():
            _merge(node.setdefault(k, {}), v)
    elif isinstance(value, list):
        node = tree.setdefault("list", {"lengths": [], "items": {}})
        node["lengths"].append(len(value))
        for item in value:
            _merge(node["items"], item)
    else:
        tree.setdefault("types", set()).add(type(value).__name__)
    return tree


def key_tree(value):
    """Merged shape of value: every list element contributes its keys."""
    return _merge({}, value)


def render(tree, name="$", indent=0, max_depth=15):
    lines = []
    pad = "  " * indent
    types = sorted(tree.get("types", ()))
    if types:
        lines.append(f"{pad}{name}: {'|'.join(types)}")
    if "object" in tree:
        lines.append(f"{pad}{name}: object")
        if indent < max_depth:
            for k in sorted(tree["object"]):
                lines += render(tree["object"][k], k, indent + 1, max_depth)
    if "list" in tree:
        n = tree["list"]["lengths"]
        lines.append(f"{pad}{name}: list (count {len(n)}, length {min(n)}..{max(n)})")
        if indent < max_depth and tree["list"]["items"]:
            lines += render(tree["list"]["items"], "[]", indent + 1, max_depth)
    return lines
