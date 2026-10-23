"""Offline approximation of `omarchy plugin validate` for CI on machines
without the Omarchy shell. Mirrors the documented checks: schemaVersion 1,
required fields, kinds <-> entryPoints, entry files exist, safe relative
paths, reserved id prefix, no symlinks."""
import json
import os
import sys

KIND_KEYS = {"bar-widget": "barWidget", "bar": "bar", "panel": "panel",
             "overlay": "overlay", "menu": "menu", "service": "service"}


def validate(root):
    errors = []
    path = os.path.join(root, "manifest.json")
    try:
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
    except Exception as e:  # noqa: BLE001
        return ["manifest.json: %s" % e]
    if m.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    for key in ("id", "name", "version", "kinds", "entryPoints"):
        if key not in m:
            errors.append("missing required field %r" % key)
    if str(m.get("id", "")).startswith("omarchy."):
        errors.append("id must not use the reserved omarchy.* prefix")
    if "." not in str(m.get("id", "")):
        errors.append("id should be namespaced (vendor.name)")
    kinds = m.get("kinds") or []
    eps = m.get("entryPoints") or {}
    for kind in kinds:
        key = KIND_KEYS.get(kind)
        if key is None:
            errors.append("unknown kind %r" % kind)
            continue
        ep = eps.get(key)
        if not ep:
            errors.append("kind %r has no entryPoints.%s" % (kind, key))
            continue
        if os.path.isabs(ep) or ".." in ep.split("/"):
            errors.append("entry point %r is not a safe relative path" % ep)
        if not os.path.isfile(os.path.join(root, ep)):
            errors.append("entry point file %r does not exist (case matters)" % ep)
    if "bar-widget" in kinds:
        bw = m.get("barWidget") or {}
        if not bw.get("displayName"):
            errors.append("barWidget.displayName is required")
        if bw.get("defaultSection") not in (None, "left", "centerBegin", "center", "centerEnd", "tray", "right"):
            errors.append("barWidget.defaultSection is not a bar section")
        for entry in bw.get("schema", []):
            if entry.get("type") not in ("boolean", "integer", "string", "enum", "path"):
                errors.append("schema key %r has unknown type %r" % (entry.get("key"), entry.get("type")))
    for dirpath, dirnames, filenames in os.walk(root):
        if ".git" in dirnames:
            dirnames.remove(".git")
        for name in dirnames + filenames:
            if os.path.islink(os.path.join(dirpath, name)):
                errors.append("symlink in plugin folder: %s" % os.path.join(dirpath, name))
    return errors


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    errs = validate(root)
    for e in errs:
        print("error:", e)
    print("manifest ok" if not errs else "%d problem(s)" % len(errs))
    sys.exit(1 if errs else 0)
