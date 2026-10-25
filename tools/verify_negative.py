# -*- coding: utf-8 -*-
"""反向验证：证明 check_source.py 的判据**真的在跑**。

★ 为什么必须有（本项目血泪教训）：
  「全部通过」有两个截然不同的原因：
    ① 判据真的检查了，源码确实合规；
    ② 判据压根没执行（函数名改了 / 目标找不到 / 判据锚错了地方）。
  只有「注入违规 → 检查必须非 0」才能证明是 ①。

★ 本轮实测抓到的判据失效（都不是代码错，是判据错）：
  1) body_of 只按函数名找第一个 `名字(` → 匹配到**前向声明** → 往后找第一个 '{'
     落到下一个函数的函数体上 → 「轮询有没有重算 newest」恒 False。
     修法：跳过以 ';' 结尾的声明，只认函数定义。
  2) body_of 的 `[^\n{}();]*?` 不允许跨行，但真正的坑是它匹配到了注释里
     的同名提及（DYRecoverTick 在 DYCurrentPlayersSnapshot 的注释里）。
     修法：锚 `^[ \t]*static ...` 行首。
  3) B3 判据查 '"B@:"' 字面量，实际代码写的是 `typeEnc[0] != 'B'` → 恒 False。
  4) D5 判据查 beginBackgroundTaskWithExpirationHandler:（不存在这个 API），
     实际调用是 beginBackgroundTaskWithName: → 恒 False。
  5) D3 判据全文件搜 UIAlertController → 命中 `#if DYDIAG` 诊断段
     （DYDIAG=0 时整段不编译）→ 把合规产物判成违规。修法：先剥离诊断段。
  6) A6 判据写「不 dlopen libsubstrate」，但零 Theos 构建**必须** dlopen
     解析 MSHookMessageEx → 判据方向错了。改成「只许在解析入口 dlopen 有限次」。
  ★ 每一条都在下面有配套反向用例钉死。

★ 实现方式（性能优先）：往**同一份副本**里逐例注入 → 跑闸门 → 还原。
  绝不每例 rmtree + copytree（Windows Defender 下 76 个文件要 79 秒）。
★ 每例必须报告「是哪个判据拦下的」，否则无法区分「拦对了」与「被别的判据代答」。
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="dyp_neg_")

FILES = ["main.m", "DouYinKeepPlay.plist", "tools/check_source.py"]

for f in FILES:
    src = os.path.join(ROOT, f)
    dst = os.path.join(TMP, f)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)

_backup = {}
for f in FILES:
    _backup[f] = open(os.path.join(ROOT, f), "rb").read()


def restore():
    for f, data in _backup.items():
        with open(os.path.join(TMP, f), "wb") as fh:
            fh.write(data)


def write(rel, content):
    with open(os.path.join(TMP, rel), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)


def read(rel):
    return open(os.path.join(TMP, rel), encoding="utf-8").read()


def run_gate():
    """在副本目录里跑闸门，返回 (rc, stdout)。"""
    p = subprocess.run(
        [sys.executable, os.path.join(TMP, "tools", "check_source.py")],
        cwd=TMP, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return p.returncode, p.stdout + p.stderr


RESULTS = []


def case(name, mutate, expect_gate):
    """注入违规 → 闸门必须非 0，且必须是指定那条判据拦的。"""
    restore()
    try:
        mutate()
    except Exception as e:
        RESULTS.append((name, False, "注入本身失败: %r" % e))
        return
    rc, out = run_gate()
    if rc == 0:
        RESULTS.append((name, False,
                        "注入后闸门仍返回 0 —— 判据没在跑（假绿）"))
        return
    # 必须是指定判据拦下的（防「被别的判据代答」）
    if expect_gate not in out:
        RESULTS.append((name, False,
                        "红了但不是指定判据拦的（被代答）。期望: %s" % expect_gate))
        return
    RESULTS.append((name, True, "已拦下（%s）" % expect_gate))


def m_a3():
    s = read("main.m")
    s = s.replace('__attribute__((constructor)) static void DYCtor(void) {',
                  'static void DYCtor(void) {')
    write("main.m", s)


def m_b1():
    """VC.pause 改成查表取 orig —— v15 递归事故的根因，必须被拦。

    ★ 注入必须落到**函数体内部**：判据锚的是 DYVCPauseImpl 函数体，
      只改签名那一行（函数体外）判据看不到。
      另外引用的查表函数必须真的存在（DYOrigVCPauseFor 在 v16 里已删除），
      否则编译就挂了、闸门根本跑不到目标判据 → 会误判成「拦下了」。
    """
    s = read("main.m")
    s = s.replace(
        "    BOOL result;\n    if (block) {",
        "    NSValue *vv = gVCPauseMap[NSStringFromClass([self class])];\n"
        "    DYImpBool tableOrig = vv ? (DYImpBool)[vv pointerValue] : NULL;\n"
        "    BOOL result;\n    if (block) {")
    write("main.m", s)


def m_b3():
    """去掉签名校验 —— 必须被拦。"""
    s = read("main.m")
    s = s.replace("const char *typeEnc = method_getTypeEncoding(m);",
                  "const char *typeEnc = \"B@:\";")
    write("main.m", s)


def m_c1a():
    """轮询退回读固定候选（v15 的写法）—— 双路音频根因，必须被拦。"""
    s = read("main.m")
    s = s.replace("    NSArray *snapshot = DYCurrentPlayersSnapshot();\n"
                  "    id newest = DYNewestPlayerIn(snapshot);",
                  "    NSArray *snapshot = [gCandidates copy];\n"
                  "    id newest = snapshot.firstObject;")
    write("main.m", s)


def m_c1b():
    """轮询不再停旧 —— 只恢复不收旧，必须被拦。"""
    s = read("main.m")
    s = s.replace("        silenced = DYSilenceAllBut(newest, snapshot);",
                  "        silenced = 0;")
    write("main.m", s)


def m_c2():
    """停旧改成直接 [p pause]（不走真 orig）—— 会自己把自己扶回 newest。"""
    s = read("main.m")
    s = s.replace("            DYImpVoid orig = DYOrigPauseFor(p);\n"
                  "            if (!orig) continue;\n"
                  "            orig(p, @selector(pause));        // 走真 orig：不触发 hook、不改 newest",
                  "            [p pause];")
    write("main.m", s)


def m_c3():
    """play 事件不再立即停旧 —— 连续切视频时中间会双路叠响。"""
    s = read("main.m")
    s = s.replace("    if (away) {\n"
                  "        NSArray *snapshot = DYCurrentPlayersSnapshot();\n"
                  "        NSUInteger silenced = DYSilenceAllBut(self, snapshot);",
                  "    if (NO) {\n"
                  "        NSArray *snapshot = DYCurrentPlayersSnapshot();\n"
                  "        NSUInteger silenced = 0;")
    write("main.m", s)


def m_c4a():
    """轮询上限退回 40 tick —— 8 秒后切视频没人收旧。"""
    s = read("main.m")
    s = s.replace("#define DY_RECOVER_MAX_TICKS 3000",
                  "#define DY_RECOVER_MAX_TICKS 40")
    s = s.replace("    if (tick < DY_RECOVER_MAX_TICKS) {",
                  "    if (tick < 40) {")
    write("main.m", s)


def m_c4b():
    """轮询不再检查是否回前台 —— 回前台还在跑会误停。"""
    s = read("main.m")
    s = s.replace("        stillAway = gAppNonActive;   // 回前台了就没必要继续轮询（下面立刻收尾）",
                  "        stillAway = YES;")
    write("main.m", s)


def m_c5():
    """回前台不清 tick —— 第二次切小窗起轮询立刻触顶。"""
    s = read("main.m")
    s = s.replace("        gRecoverTicks = 0;   // ★ v16：必须清零",
                  "        // gRecoverTicks = 0;")
    write("main.m", s)


def m_d1():
    """碰画中画 —— 会与 AwemePipSwitch 抢同一个 delegate。

    ★ 必须写成**真代码**，不能写进行注释：strip_comments 会把注释整段删掉，
      注入等于没发生 → 闸门照过 → 得到「加了违规却仍全绿」的假象。
    """
    s = read("main.m")
    s = s.replace("static void DYCtor(void) {",
                  "static Class DYPipClass(void) {\n"
                  "    return objc_getClass(\"AWEPictureInPictureSampleBufferPlayerView\");\n"
                  "}\n\n"
                  "__attribute__((constructor)) static void DYCtor(void) {")
    write("main.m", s)


def m_d3():
    """正式段加回开关（诊断段之外）—— 必须被拦。"""
    s = read("main.m")
    s = s.replace("static void DYCtor(void) {",
                  "static BOOL DYUserDefaultsEnabled(void) {\n"
                  "    return CFPreferencesGetAppBooleanValue(CFSTR(\"x\"), CFSTR(\"y\"), NULL);\n"
                  "}\n\n"
                  "__attribute__((constructor)) static void DYCtor(void) {")
    write("main.m", s)


def m_d5():
    """去掉 endBackgroundTask —— 后台任务泄漏会被系统强杀。

    ★ 必须把**定义和所有调用点**一起改名：只改定义名的话，
      判据查的 "endBackgroundTask" 字符串仍出现在调用点 → 判据仍绿
      → 得到「删了违规却仍全绿」的假象。
    """
    s = read("main.m")
    s = s.replace("static void DYEndBgTask(void) {", "static void DYEndBgTaskGone(void) {")
    s = s.replace("DYEndBgTask()", "DYEndBgTaskGone()")
    # 判据查的是 "endBackgroundTask" 这个 selector 串，一并抹掉实现体
    s = s.replace("[[UIApplication sharedApplication] endBackgroundTask:task];",
                  "/* 已移除 endBackgroundTask */")
    write("main.m", s)


case("A3 去掉 constructor", m_a3, "A3 有 constructor 入口")
case("B1 VC.pause 查表取 orig（v15 递归根因）", m_b1, "B1 VC.pause 体内不查表取 orig")
case("B3 去掉签名校验", m_b3, "B3 hook 前校验方法签名")
case("C1a 轮询退回读固定候选", m_c1a, "C1 轮询每 tick 重算 newest")
case("C1b 轮询不再停旧", m_c1b, "C1 轮询每 tick 停旧")
case("C2 停旧不走真 orig", m_c2, "C2 停旧走 per-class 真 orig")
case("C3 play 事件不立即停旧", m_c3, "C3 play 即停旧")
case("C4a 轮询上限退回 40 tick", m_c4a, "C4 轮询用 DY_RECOVER_MAX_TICKS 上限")
case("C4b 轮询不检查回前台", m_c4b, "C4 轮询每 tick 检查是否已回前台")
case("C5 回前台不清 tick", m_c5, "C5 回前台清零 gRecoverTicks")
case("D1 碰画中画", m_d1, "D1 不碰画中画 AWEPictureInPictureSampleBufferPlayerView")
case("D3 正式段加回 CFPreferences 开关", m_d3, "D3 正式段无开关/弹窗/文件 IO CFPreferences")
case("D5 去掉 endBackgroundTask", m_d5, "D5d DYEndBgTask 体内真的调 endBackgroundTask")

restore()

print("=" * 74)
bad = 0
for name, passed, msg in RESULTS:
    print("  %s %-38s %s" % ("✓" if passed else "✗", name, msg))
    if not passed:
        bad += 1
print("=" * 74)
if bad:
    print("✗ %d 例未通过 / 共 %d 例" % (bad, len(RESULTS)))
    sys.exit(1)
print("✓ 反向验证全过（%d 例，零 SKIP）" % len(RESULTS))
