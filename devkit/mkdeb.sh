#!/bin/sh
# 打 deb（不依赖 Theos / dpkg-deb，纯 Python 拼 ar）
#
# 用法：sh devkit/mkdeb.sh <arch> <version>
set -eu

ARCH="${1:?用法: mkdeb.sh <arch> <version>}"
VER="${2:?用法: mkdeb.sh <arch> <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDDIR="${3:-$ROOT/.build}"
STAGE="$BUILDDIR/stage"
OUT="$BUILDDIR/out"
PKG="com.liehuu.douyinkeepplay"
NAME="DouYinKeepPlay"

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" \
         "$STAGE/Library/MobileSubstrate/DynamicLibraries" \
         "$OUT"

# ---- 载荷：dylib + 注入过滤 ----
cp "$BUILDDIR/$NAME.dylib" "$STAGE/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib"
cp "$ROOT/$NAME.plist"     "$STAGE/Library/MobileSubstrate/DynamicLibraries/$NAME.plist"

# 权限
find "$STAGE" -type d -exec chmod 755 {} \;
find "$STAGE" -type f -exec chmod 644 {} \;
# ★ dylib 必须 755：644 会被 ellekit / RootHide 的加载器拒绝，
#   表现是「装了完全没反应」，dpkg 却不报任何错。
chmod 755 "$STAGE/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib"

# ---- control ----
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Name: 抖音小窗播放保持
Version: $VER
Architecture: $ARCH
Description: 抖音小窗（画中画）/后台播放保持 + 单一音频源保证 + 用户暂停保持
 v17 修复（用户实测回归）：切到小窗后点暂停，视频立刻又开始播。
  v16 把轮询窗口延长到整个后台期，但轮询不检查「用户主动暂停」标记，
  暂停后下一 tick 又被 play 回来。v17：每个 tick 恢复前先读该标记，置位就不恢复；
  用户重新点播放则正常恢复（不会死锁）。
  已知局限：切小窗后 2 秒内点暂停仍会被拦截（v11 起的保持播放机制），
  超过 2 秒点暂停一定生效。
 v16 修复（用户实测）：小窗里切到下一条视频后，仍留有上一条的声音。
  根因：v15 的后台轮询把「进小窗那一刻的旧播放器」写进候选，
  之后 8 秒内每 0.2 秒把它 play 回来；用户在这窗口内切视频，
  新视频开始播、旧播放器又被轮询复活 → 两路音频同时响。
  v16 修法：轮询每 tick 从注册表现算 newest；非 newest 且仍在响的用真 orig pause 静默停掉；
  新播放器一 play 立刻停掉其它。轮询窗口延长到整个后台期。
 v11 验证有效的播放保持逻辑全部保留，未触摸。
 不含：锁屏遥控、小窗切视频、设置页、开关、日志文件、弹窗。
 与 AwemePipSwitch（小窗切视频）和 AwemeNextPrev-pure（锁屏上一首/
 下一首）作用点不同，可同装。
 仅注入抖音进程。
Maintainer: liehuu
Author: liehuu
Section: Tweaks
Depends: firmware (>= 13.0), mobilesubstrate
EOF
chmod 644 "$STAGE/DEBIAN/control"

# ---- postinst ----
# ★★ 绝不 respring / sbreload / killall SpringBoard。
#   postinst 是 dpkg 事务的最后一步，在 Sileo 里安装时重启 SpringBoard
#   会把前台的 Sileo 一起杀掉 → status 没写完、lock 没释放 →
#   锁残留 + 半装，之后任何 deb 都装不上。真实事故，别再加回来。
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
printf '\n'
printf '抖音小窗播放保持 已安装。\n'
printf '\n'
printf '作用：\n'
printf '  1) 切小窗 / 进后台时视频保持播放，不自动暂停。\n'
printf '  2) 小窗里切到下一条视频时，上一条的声音会被收掉。\n'
printf '  3) 小窗里点暂停生效（v17 修复）。\n'
printf '     注：切进小窗后 2 秒内点暂停可能无效，\n'
printf '     这是保持播放的固有取舍；超过 2 秒就一定生效。\n'
printf '     （v16 修复：旧版会出现「新视频在放、旧视频声音还在」）\n'
printf '\n'
printf '生效方式：完全退出抖音（上滑杀掉）再重新打开。\n'
printf '\n'
printf '可与其他抖音插件同装：\n'
printf '  · AwemePipSwitch（小窗切上一条/下一条）\n'
printf '  · AwemeNextPrev-pure（锁屏上一首/下一首）\n'
printf '\n'
printf '本插件没有开关、没有日志、没有弹窗。\n'
printf '\n'
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

# ---- 打包（纯 Python 拼 ar）----
PYBIN="$(command -v python3 || command -v python)"
OUT_DEB="$OUT/${PKG}_${VER}_${ARCH}.deb"

"$PYBIN" - "$STAGE" "$OUT_DEB" <<'PYEOF'
import io
import lzma
import os
import sys
import tarfile

stage, out_deb = sys.argv[1], sys.argv[2]
DEB_MAGIC = b"!<arch>\n"
MTIME = 0  # 固定 mtime，保证可复现构建


def make_ar(name, data):
    """拼一个 ar 成员（GNU 风格，名字后跟 / 终止符）。"""
    hdr = name.encode() + b"/"
    hdr = hdr.ljust(16)
    hdr += b"0".ljust(12)      # mtime
    hdr += b"0".ljust(6)       # uid
    hdr += b"0".ljust(6)       # gid
    hdr += b"100644".ljust(8)  # mode
    hdr += str(len(data)).encode().ljust(10)
    hdr += b"`\n"
    assert len(hdr) == 60, len(hdr)
    pad = b"\n" if len(data) % 2 else b""
    return hdr + data + pad


def tar_bytes(dirpath, arcprefix, skip_top=()):
    """把目录打成 tar 字节流（GNU_FORMAT，排除 PAX 扩展头）。

    ★★ 只把**文件**交给 addfile 读内容，目录用 addfile(ti) 不带文件对象。
       早期写法把 dirs 和 files 混在一起遍历并对每一项都 open()，
       遇到目录就 IsADirectoryError（macOS runner 实测崩在这一行）。

    ★ skip_top：顶层要跳过的目录名（如 ("DEBIAN",)）。
       data.tar **绝不能含 DEBIAN/**：rootless 上 / 只读，装到一半要写
       DEBIAN 会直接失败 → 整包装不上。这不是「风格问题」，是装不上。
    """
    buf = io.BytesIO()
    tf = tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT)
    for root, dirs, files in os.walk(dirpath):
        dirs.sort()
        rel = os.path.relpath(root, dirpath)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if rel != ".":
            # 顶层过滤：DEBIAN 整个子树不进 data.tar
            if depth == 1 and rel.split(os.sep)[0] in skip_top:
                dirs[:] = []
                continue
            ti = tf.gettarinfo(root, arcname=arcprefix + rel.replace(os.sep, "/"))
            ti.mtime = MTIME
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            tf.addfile(ti)
        else:
            dirs[:] = [d for d in dirs if d not in skip_top]
        for name in sorted(files):
            full = os.path.join(root, name)
            arc = arcprefix + os.path.relpath(full, dirpath).replace(os.sep, "/")
            ti = tf.gettarinfo(full, arcname=arc)
            ti.mtime = MTIME
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            if os.path.islink(full):
                ti.type = tarfile.SYMTYPE
                ti.linkname = os.readlink(full)
                tf.addfile(ti)
            else:
                with open(full, "rb") as fh:
                    tf.addfile(ti, fh)
    tf.close()
    return buf.getvalue()


def check_no_pax(data):
    """dpkg 不认 PAX 扩展头（typeflag 'x'），出现就说明格式错了。"""
    tf = tarfile.open(fileobj=io.BytesIO(data))
    for m in tf.getmembers():
        assert m.type not in (tarfile.GNUTYPE_LONGNAME,
                              tarfile.GNUTYPE_LONGLINK), \
            "出现 GNU 长名扩展头，dpkg 不认: %s" % m.name
    tf.close()


# debian-binary
db = b"2.0\n"

# control.tar.gz
control_bytes = tar_bytes(os.path.join(stage, "DEBIAN"), "./")
check_no_pax(control_bytes)
c = io.BytesIO()
with __import__("gzip").GzipFile(fileobj=c, mode="wb", mtime=MTIME) as gz:
    gz.write(control_bytes)
control_tar = c.getvalue()

# data.tar.xz
data_bytes = tar_bytes(stage, "./", skip_top=("DEBIAN",))
# ★★ data.tar 绝不能含 DEBIAN/ 目录：rootless 上 / 只读，
#    装到一半要写 DEBIAN 会直接失败 → 整包装不上。
names = [m.name for m in tarfile.open(fileobj=io.BytesIO(data_bytes)).getmembers()]
assert not any(n.startswith("./DEBIAN") or n.startswith("DEBIAN") for n in names), \
    "data.tar 含 DEBIAN/：%s" % [n for n in names if "DEBIAN" in n]
data_tar = lzma.compress(data_bytes, format=lzma.FORMAT_XZ)

with open(out_deb, "wb") as fh:
    fh.write(DEB_MAGIC)
    fh.write(make_ar("debian-binary", db))
    fh.write(make_ar("control.tar.gz", control_tar))
    fh.write(make_ar("data.tar.xz", data_tar))

print("→ 打包完成:", out_deb)
print("  大小:", os.path.getsize(out_deb), "B")
print("  data 条目:", len(names))
PYEOF

echo "→ 产物自证"
"$PYBIN" - "$OUT_DEB" <<'PYEOF'
import io
import lzma
import sys
import tarfile

p = sys.argv[1]
d = open(p, "rb").read()
assert d[:8] == b"!<arch>\n", "deb magic 不对"

pos = 8
members = {}
while pos < len(d):
    hdr = d[pos:pos + 60]
    # ★ GNU ar 成员名以 "/" 结尾（make_ar 里 name + b"/"），比较前必须去掉，
    #   否则 {"debian-binary/"} != {"debian-binary"} → 断言失败。
    #   （macOS runner 实测：deb 已正确打出，自证脚本却在这里误报。）
    name = hdr[0:16].decode().strip().rstrip("/")
    size = int(hdr[48:58].decode().strip())
    members[name] = d[pos + 60:pos + 60 + size]
    pos += 60 + size + (size % 2)

assert set(members) == {"debian-binary", "control.tar.gz", "data.tar.xz"}, \
    "ar 成员不对: %s" % list(members)

t = tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]))
ctl = None
for m in t.getmembers():
    if m.name.lstrip("./").endswith("control"):
        ctl = t.extractfile(m).read().decode()
assert ctl and "Package:" in ctl and "Version:" in ctl, "control 不完整"

raw = lzma.LZMAFile(io.BytesIO(members["data.tar.xz"]),
                    format=lzma.FORMAT_XZ).read()
t2 = tarfile.open(fileobj=io.BytesIO(raw))
entries = [m.name for m in t2.getmembers()]
assert not any("DEBIAN" in n for n in entries), "data.tar 含 DEBIAN/"
assert any("DouYinKeepPlay.dylib" in n for n in entries), "缺 dylib"

print("  ✓ ar 结构 / control / data.tar 全部正确")
print("  ✓ data 条目 %d 个，无 DEBIAN/" % len(entries))
PYEOF
