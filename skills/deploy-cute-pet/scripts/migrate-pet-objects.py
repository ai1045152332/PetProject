#!/usr/bin/env python3
"""把 pet-images/objects 的平铺布局迁移成「设备目录/一次上传一个文件夹」。

旧:  objects/<deviceKey>/<label>-original-<hex>、objects/<deviceKey>/<id>
新:  objects/<deviceKey>/<batch>/original-<label>.png
     objects/<deviceKey>/<batch>/<state>-<label>.png

- batch 目录名取该次上传的 createdAt（UTC）加 6 位随机后缀。
- 记录里的 sourceId / objectId 同步改成相对设备目录的路径；id 保持不变（客户端缓存键）。
- 已经是新布局的记录、或该设备有正在生成的任务时整台跳过。
- 默认 dry-run，只打印计划；加 --apply 才真正移动文件并改写 json。

用法: python3 migrate-pet-objects.py [--apply]
"""

import json
import os
import random
import sys
import time

ROOT = os.environ.get("PET_IMAGE_ROOT", "/opt/petserver/data/pet-images")
OBJECTS = os.path.join(ROOT, "objects")
LIBRARIES = os.path.join(ROOT, "libraries")
DEFAULT_STAMP = "19700101-000000"
GENERATING = {"beautifying", "animating", "encoding"}


def file_ext(path):
    try:
        with open(path, "rb") as handle:
            head = handle.read(12)
    except OSError:
        return ".img"
    if head.startswith(b"\x89PNG"):
        return ".png"
    if head.startswith(b"\xff\xd8"):
        return ".jpg"
    if head.startswith(b"GIF8"):
        return ".gif"
    return ".img"


def safe_label(name):
    keep = "".join(ch for ch in name if ch.isalnum() or ch in "_-")
    return keep[:24] or "pet"


def source_label(source_id):
    return safe_label(source_id.split("-original-")[0])


def batch_name(created_at):
    stamp = DEFAULT_STAMP
    try:
        parsed = time.strptime(created_at[:19], "%Y-%m-%dT%H:%M:%S")
        stamp = time.strftime("%Y%m%d-%H%M%S", parsed)
    except (ValueError, TypeError):
        pass
    return stamp + "-" + "".join(random.choices("0123456789abcdef", k=6))


def migrate_library(name, apply):
    key = name[: -len(".json")]
    lib_path = os.path.join(LIBRARIES, name)
    with open(lib_path, "r", encoding="utf-8") as handle:
        library = json.load(handle)
    images = library.get("images") or []
    if any(image.get("status") in GENERATING for image in images):
        print("  skip %s: generation in flight" % key[:12])
        return False

    groups = {}
    for image in images:
        source = image.get("sourceId") or ""
        if not source or "/" in source:
            continue
        groups.setdefault(source, []).append(image)
    if not groups:
        print("  skip %s: already in batch layout" % key[:12])
        return False

    changed = False
    for source, items in groups.items():
        source_path = os.path.join(OBJECTS, key, source)
        if not os.path.exists(source_path):
            print("  skip group %s: original upload missing" % source)
            continue
        batch = batch_name(items[0].get("createdAt"))
        label = source_label(source)
        source_rel = "%s/original-%s%s" % (batch, label, file_ext(source_path))
        print("  %s/ -> %s/" % (key[:12], batch))
        move(key, source, source_rel, apply)
        for image in items:
            state = image.get("state") or "shared"
            old_id = image.get("id") or ""
            old_path = os.path.join(OBJECTS, key, old_id)
            if old_id == source:
                output_rel = source_rel
            elif os.path.exists(old_path):
                output_rel = "%s/%s-%s%s" % (batch, state, label, file_ext(old_path))
                move(key, old_id, output_rel, apply)
            else:
                output_rel = "%s/%s-%s.png" % (batch, state, label)
                print("    no output file for %s record; expected at %s" % (image.get("status"), output_rel))
            image["sourceId"] = source_rel
            image["objectId"] = output_rel
        changed = True

    if changed and apply:
        tmp = lib_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(library, handle, ensure_ascii=False, separators=(",", ":"))
        os.chmod(tmp, 0o600)
        os.replace(tmp, lib_path)
        print("  rewrote %s" % name)
    return changed


def move(key, src, dst, apply):
    print("    move %s -> %s" % (os.path.basename(src), dst))
    if apply:
        target = os.path.join(OBJECTS, key, dst)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        os.replace(os.path.join(OBJECTS, key, src), target)


def main():
    apply = "--apply" in sys.argv[1:]
    if not os.path.isdir(OBJECTS) or not os.path.isdir(LIBRARIES):
        sys.exit("pet-images directories not found under %s" % ROOT)
    print("mode: %s" % ("APPLY" if apply else "dry-run"))
    changed = 0
    for name in sorted(os.listdir(LIBRARIES)):
        if not name.endswith(".json") or name.startswith("quota-"):
            continue
        if migrate_library(name, apply):
            changed += 1
    print("done: %d device library migrated" % changed)


if __name__ == "__main__":
    main()
