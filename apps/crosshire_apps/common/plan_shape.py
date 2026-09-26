"""Hash of a plan's shape: operators, join types and tables only, never values or ids."""
import hashlib


def plan_hash(nodes):
    """nodes: preorder list of dicts with node_name, join_type, table_name, child_count."""
    if not nodes:
        return None
    parts = [
        f"{n['node_name']}|{n.get('join_type') or ''}|{n.get('table_name') or ''}|{n.get('child_count', 0)}"
        for n in nodes
    ]
    return hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()[:16]
