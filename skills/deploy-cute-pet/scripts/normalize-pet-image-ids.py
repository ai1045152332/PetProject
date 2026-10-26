#!/usr/bin/env python3
"""把历史记录的图片 ID 规范成 32 位小写 hex。

客户端 CustomSpriteStore.validID 只接受 32 位 hex（ID 同时是本地缓存文件名 cloud-<id>.img），
早期服务端把「文件名标签 + 8 位 hex」直接当 ID，导致这些历史图片在 App 里下载/应用被拒。
对象文件名已与 ID 解耦（按 <batch>/<state>-<label>.png 存放），所以这里只改 json，
不动任何图片文件；同一张旧图被多个状态共享时仍映射到同一个新 ID。

默认 dry-run，加 --apply 才写回。

用法: python3 normalize-pet-image-ids.py [--apply]
"""

import json
import os
import re
import secrets
import sys

ROOT = os.environ.get("PET_IMAGE_ROOT", "/opt/petserver/data/pet-images")
LIBRARIES = os.path.join(ROOT, "libraries")
HEX32 = re.compile(r"^[0-9a-f]{32}$")


def normalize(library):
    images = library.get("images") or []
    mapping = {}
    for image in images:
        old = image.get("id") or ""
        if not old or HEX32.match(old):
            continue
        mapping.setdefault(old, secrets.token_hex(16))
        image["id"] = mapping[old]
    if not mapping:
        return 0
    for state, value in list((library.get("currentIds") or {}).items()):
        if value in mapping:
            library["currentIds"][state] = mapping[value]
    if library.get("currentId") in mapping:
        library["currentId"] = mapping[library["currentId"]]
    return len(mapping)


def main():
    apply = "--apply" in sys.argv[1:]
    print("mode: %s" % ("APPLY" if apply else "dry-run"))
    changed = 0
    for name in sorted(os.listdir(LIBRARIES)):
        if not name.endswith(".json") or name.startswith("quota-"):
            continue
        path = os.path.join(LIBRARIES, name)
        with open(path, "r", encoding="utf-8") as handle:
            library = json.load(handle)
        count = normalize(library)
        if not count:
            continue
        changed += 1
        print("  %s: %d legacy id(s) -> 32-hex" % (name[:12], count))
        if apply:
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(library, handle, ensure_ascii=False, separators=(",", ":"))
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
    print("done: %d library normalized" % changed)


if __name__ == "__main__":
    main()
