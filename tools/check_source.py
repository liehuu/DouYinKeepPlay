# -*- coding: utf-8 -*-
"""DouYinKeepPlay v16 源码闸门。

检查的是「装上去会不会出问题」，不是「编不编得过」。本项目的历史事故：
  · v15 让抖音不定时闪退（511 帧自我递归 → 栈溢出撞保护页）
  · v12 多个视频声音一起响（用户实测，回退）
  · v15 小窗切下一条视频后仍留上一条的声音（用户实测，v16 修）

★ 判据设计纪律（踩过的坑，别再犯）：
  1) 判据必须锚到**函数体**：用 body_of() + 花括号配平取函数正文。
     全文件搜"某关键字"会被同名注释/别处用法代答 → 假绿。
  2) 禁项不能用泛词：系统库里必然存在的词（pause / rate）会把合规产物判违规。
     必须用精确 selector 写法（sendEvent: / setRate: / beginBackgroundTaskWithExpirationHandler:）。
  3) 每条禁项判据都要有配套反向用例（verify_negative.py）证明它真的在跑。
  4) here-doc 生成的字段（control 等）必须先提正文再判，注释里那几个字会误伤。
"""
import re
import sys

SRC = "main.m"
PLIST = "DouYinKeepPlay.plist"

errors = []
checks = 0


def ok(cond, name, why=""):
    global checks
    checks += 1
    if cond:
        print("  ✓", name)
    else:
        print("  ✗", name)
        if why:
            print("      原因：", why)
        errors.append(name)


def strip_comments(s):
    """去掉行注释与块注释（保留字符串字面量，避免误删 "@\"...\"）里的内容）。"""
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '"' or (c == '@' and i + 1 < n and s[i + 1] == '"'):
            q = '"'
            j = i + (2 if c == '@' else 1)
            out.append(s[i:j])
            while j < n:
                if s[j] == '\\':
                    out.append(s[j:j + 2])
                    j += 2
                    continue
                out.append(s[j])
                if s[j] == q:
                    j += 1
                    break
                j += 1
            i = j
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            while i < n and s[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def body_of(code, func_name):
    """取函数体（含花括号），用花括号配平。

    ★★ 必须锚「static ... 函数名(」这一行 —— 早期版本只按函数名找第一个
       `名字(`，结果匹配到**别处注释里**的同名提及（DYRecoverTick 在
       DYCurrentPlayersSnapshot 的注释里被提过），取到的是那个函数的函数体，
       于是「轮询里有没有重算 newest」恒判 False，而源码其实是对的。
       这是「判据被代答」的一种新形态：不是被别处代码代答，是被注释代答。
    """
    # 函数定义：行首（可有前导空白）以 static 开头，中间是返回类型，最后是 名字(
    # ★★ 必须跳过前向声明（`static void DYRecoverTick(void);`）：它也在行首且同形态，
    #   但它后面跟的是分号不是函数体。若取到声明，往后找第一个 '{' 会落到
    #   **下一个函数**的函数体上（实测取到 DYCurrentPlayersSnapshot），
    #   于是「轮询里有没有重算 newest」恒判 False，而源码其实是对的。
    #   修法：匹配到的行必须以 '{' 或（跨行的）函数体开头，不能以 ';' 结尾。
    for m in re.finditer(r'(?m)^[ \t]*static[ \t]+[^\n{}();]*?\b' + re.escape(func_name) +
                         r'[ \t]*\(', code):
        tail = code[m.end():m.end() + 400]
        semi = tail.find(';')
        brace = tail.find('{')
        if semi != -1 and (brace == -1 or semi < brace):
            continue        # 这是前向声明，跳过
        i = code.find('{', m.end() - 1)
        if i < 0:
            return None
        break
    else:
        return None
    depth = 0
    j = i
    while j < len(code):
        ch = code[j]
        if ch == '"' or (ch == '@' and j + 1 < len(code) and code[j + 1] == '"'):
            q = '"'
            j += (2 if ch == '@' else 1)
            while j < len(code):
                if code[j] == '\\':
                    j += 2
                    continue
                if code[j] == q:
                    break
                j += 1
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return code[i:j + 1]
        j += 1
    return None


src = open(SRC, encoding='utf-8').read()
code = strip_comments(src)   # 判据一律在去注释后的代码上做

print("=" * 66)
print("DouYinKeepPlay v16 源码闸门")
print("=" * 66)

# ============================================================
# A 组：结构完整性（先保证「能编出来」，错了后面全白跑）
# ============================================================
print("\n[A] 结构")

ok(code.count('{') == code.count('}'),
   "A1 花括号配平",
   "数量不等：%d vs %d" % (code.count('{'), code.count('}')))
ok(code.count('(') == code.count(')'),
   "A2 圆括号配平",
   "数量不等：%d vs %d" % (code.count('('), code.count(')')))
ok('__attribute__((constructor))' in code,
   "A3 有 constructor 入口",
   "没有构造器 → 插件压根不会加载")

# A4：v16 新增函数必须真的存在（否则下面所有 v16 判据都是假绿）
for fn in ("DYCurrentPlayersSnapshot", "DYNewestPlayerIn", "DYSilenceAllBut"):
    ok(re.search(r'\b' + fn + r'\s*\(', code) is not None,
       "A4 存在 %s" % fn,
       "v16 核心函数缺失 → 下面所有 v16 判据会全部假绿")

# A5：v16 依赖的探测函数必须有前向声明或先定义
for fn in ("DYIsPaused", "DYPlay", "DYOrigPauseFor"):
    d = re.search(r'^static\s+[^\n]*?\b' + fn + r'\s*\(', code, re.M)
    ok(d is not None, "A5 有 %s 声明/定义" % fn,
       "缺失会导致编译失败（CI 首编红）")

# A6 外部依赖：MSHookMessageEx 必须运行时解析（零 Theos 构建不链接 Substrate），
#    但只许在解析入口 dlopen 少数几次，不许每个 hook 点各自 dlopen。
ok("pMSHookMessageEx" in code, "A6 用运行期解析的 MSHookMessageEx",
   "零 Theos 构建不链接 Substrate，只能 dlsym 取")
ok(code.count("dlopen(") <= 3, "A6 dlopen 次数 ≤3（只在解析入口）",
   "每个 hook 点各自 dlopen → RootHide 下可能加载第二份 → 双引擎改同一张方法表")

# ============================================================
# B 组：崩宿主防护（v15 的真实事故：511 帧递归）
# ============================================================
print("\n[B] 崩宿主防护")

# B1 per-class orig：禁止再用「按类名查表」取 orig（那是 v15 递归的根因）
#    允许存在的：安装 hook 时把 orig 塞进 map（诊断计数），但热路径取 orig
#    必须走 block 捕获。判据：DYVCPauseImpl 体内不许出现查表调用。
vc_pause = body_of(code, "DYVCPauseImpl")
ok(vc_pause is not None, "B1 找到 DYVCPauseImpl 函数体")
if vc_pause:
    ok("gVCPauseMap" not in vc_pause and "gOrigPauseMap" not in vc_pause,
       "B1 VC.pause 体内不查表取 orig",
       "按类名查表 → 父子类交叉时 orig 是父类 trampoline → 无限递归（v15 事故）")

# B2 重入闸必须存在且阈值合理
ok("gHookReentry" in code and "DY_REENTRY_LIMIT" in code,
   "B2 有同线程重入深度闸")
m = re.search(r'#define\s+DY_REENTRY_LIMIT\s+(\d+)', code)
if m:
    v = int(m.group(1))
    ok(2 <= v <= 12, "B2 重入阈值 %d 在 2~12" % v,
       "太低会把用户手动暂停吞掉，太高挡不住递归")

# B3 hook 前必须校验方法签名（VC.pause 必须返回 BOOL）
#    ★★ 判据必须锚函数体 + 查**实际写法**：真实实现是
#         const char *typeEnc = method_getTypeEncoding(m);
#         if (!typeEnc || typeEnc[0] != 'B') { ...跳过... }
#      早期判据查 '"B@:"' 字面量 → 恒 False（代码压根没用那个写法）。
#      注释里虽然写着 B@:，但那是给人看的，不是给编译器的。
hook_vc = body_of(code, "DYHookBackgroundStateMachine")
ok(hook_vc is not None, "B3 找到 DYHookBackgroundStateMachine 函数体")
if hook_vc:
    ok("method_getTypeEncoding" in hook_vc,
       "B3 hook 前校验方法签名",
       "不校验 → 把 void 实现当 BOOL 读返回值 → 未定义行为")
    ok("'B'" in hook_vc or "\"B@:\"" in hook_vc,
       "B3 期望 VC.pause 返回 BOOL（首字符 B）",
       "v13 起 VC.pause 返回 BOOL，与底层 void pause 不同，必须分开")

# B4 只 hook 类自己声明的 selector（否则子类被多包一层 trampoline）
if hook_vc:
    ok("DYClassDeclaresSelector" in hook_vc or "class_copyMethodList" in hook_vc,
       "B4 只 hook 自身声明的 selector",
       "走继承链会拿到父类（可能已被 hook）的实现")

# ============================================================
# C 组：v16 核心 —— 单一音频源（用户实测：切下一条仍留上一条声音）
# ============================================================
print("\n[C] 单一音频源（v16）")

# C1 轮询必须现算 newest，不许用固定候选
tick = body_of(code, "DYRecoverTick")
ok(tick is not None, "C1 找到 DYRecoverTick 函数体")
if tick:
    ok("DYNewestPlayerIn" in tick,
       "C1 轮询每 tick 重算 newest",
       "用固定 gCandidates → 切视频后新视频在播、旧播放器仍被 play 回来 → 双路音频")
    ok("DYSilenceAllBut" in tick,
       "C1 轮询每 tick 停旧",
       "只恢复不停旧 → 抖音自己没停的旧音频会一直响")
    ok("gCandidates" not in tick,
       "C1 轮询体内不读 gCandidates",
       "gCandidates 是进后台那一刻的快照，切视频不更新它")

# C2 停旧必须走真 orig，不能直接 [p pause]
sil = body_of(code, "DYSilenceAllBut")
ok(sil is not None, "C2 找到 DYSilenceAllBut 函数体")
if sil:
    ok("orig(p, @selector(pause))" in sil,
       "C2 停旧走 per-class 真 orig",
       "直接 [p pause] 会走进 hook → DYTouchPlayer 把它扶回 newest → 自己拧自己")
    ok("DYIsPaused" in sil,
       "C2 停旧前判暂停态",
       "已暂停的重复 pause 是多余动作（幂等但浪费）")

# C3 play 事件必须立即停旧（不等下一个 tick）
play = body_of(code, "DYPlayerPlayImpl")
ok(play is not None, "C3 找到 DYPlayerPlayImpl 函数体")
if play:
    ok("DYSilenceAllBut" in play,
       "C3 play 即停旧",
       "只靠 0.2s 轮询 → 连续切视频时中间那段会双路叠着响")
    ok("gAppNonActive" in play,
       "C3 play 即停旧只在小窗/后台生效",
       "前台乱停播放器 → 把用户正在看的视频掐掉")
    # ★ v14 的设计必须保留：播放动作要解除「用户主动暂停」标记。
    #   否则用户点一次暂停后，即使再点播放也永远恢复不了（死锁）。
    ok("DYTouchPlayer" in play,
       "C3b play 事件解除用户主动暂停标记",
       "不解除 → 用户暂停过就再也恢复不了（v14 修的正是这个）")

# C3c ★★★ v17：轮询恢复前必须检查 gUserPausedAt（用户实测回归）
#   现象：切到小窗后点暂停，视频立刻又开始播（暂停无效）。
#   根因：v16 把轮询窗口延长到整个后台期，而 DYRecoverTick 从来不检查
#         gUserPausedAt → 暂停后下一 tick 又被 DYPlay 回来。
#         v15 的 8 秒窗口让这个 bug 变成「8 秒内偶发」，v16 放大成「永久无效」。
if tick:
    ok("gUserPausedAt" in tick,
       "C3c 轮询每 tick 检查用户主动暂停标记",
       "不检查 → 用户在小窗里点暂停会被下一 tick 复活 → 暂停无效")
    # 而且必须是「置位就不恢复」的形态，不能只读不用
    ok(re.search(r'userPaused\s*=\s*\(gUserPausedAt\s*!=\s*nil\)', tick) is not None
       or "userPaused = (gUserPausedAt != nil)" in tick,
       "C3c 暂停标记的读法正确（置位即视为已暂停）")

# C4 轮询窗口必须覆盖整个后台期（v15 只 8 秒，连续切视频会漏）
#    ★ 宏 `#define DY_RECOVER_MAX_TICKS` 在函数体**外面**，
#      所以「函数体内有没有这个宏名」和「有没有 #define」要分开判：
#      前者证明函数真的用了它，后者证明宏真的被定义了。
ok(re.search(r'#define\s+DY_RECOVER_MAX_TICKS\s+\d+', code) is not None,
   "C4 定义了 DY_RECOVER_MAX_TICKS",
   "没有定义 → 编译失败")
if tick:
    ok("DY_RECOVER_MAX_TICKS" in tick,
       "C4 轮询用 DY_RECOVER_MAX_TICKS 上限",
       "写死 40 tick = 8 秒 → 之后切视频没人收旧音频")
    ok("tick < 40" not in tick,
       "C4 不再用 40 tick 上限",
       "8 秒窗口对『保持播放期间连续切视频』不够")
    ok("gAppNonActive" in tick,
       "C4 轮询每 tick 检查是否已回前台",
       "回前台了还在跑 → 无谓耗电，且可能误停前台播放器")

# C5 回前台必须清 tick 计数（否则下一轮立刻触顶）
become = None
for m in re.finditer(r'UIApplicationDidBecomeActiveNotification', code):
    seg = code[m.start():m.start() + 1500]
    if 'gRecoverTicks' in seg:
        become = seg
        break
ok(become is not None, "C5 回前台清零 gRecoverTicks",
   "不清零 → 下次切小窗 tick 从高位继续 → 立刻触顶 → 第二次起不再停旧/恢复")

# ============================================================
# D 组：不越界（不能顺手把别的功能加回来）
# ============================================================
print("\n[D] 不越界")

# D1 不许碰小窗/画中画切视频（那是 AwemePipSwitch 的职责，两个插件同时动会打架）
for bad in ("skipByInterval", "PictureInPicture", "AWEPictureInPictureSampleBufferPlayerView"):
    ok(bad not in code, "D1 不碰画中画 %s" % bad,
       "小窗切换是另一个插件的职责；两个都动 → 抢同一个 delegate")

# D2 不许碰锁屏遥控（那是 AwemeNextPrev-pure 的职责）
for bad in ("MPRemoteCommandCenter", "nextTrackCommand", "previousTrackCommand"):
    ok(bad not in code, "D2 不碰锁屏遥控 %s" % bad,
       "锁屏上一首/下一首由 pure 1.0-2 负责，可同装但别互相覆盖")

# D3 不许有设置页 / 开关 / 弹窗 / 文件 IO（用户要求零打扰）
#    ★ 必须先剥离 `#if DYDIAG ... #endif` 诊断段再判：正式构建 DYDIAG=0，
#      整段不编译，里面的 UIAlertController/诊断函数不该算违规。
#      反之，如果这些符号出现在诊断段**之外**，才是真违规。
diag = re.search(r'(?ms)^#if\s+DYDIAG\b.*?^#endif', code)
prod_code = code[:diag.start()] + code[diag.end():] if diag else code
ok(diag is not None, "D3z 能找到 DYDIAG 诊断段并剥离",
   "找不到诊断段 → 下面 D3 判据会把诊断代码误判成违规")
for bad in ("CFPreferences", "NSUserDefaults", "UIAlertController",
            "NSFileHandle", "writeToFile"):
    ok(bad not in prod_code, "D3 正式段无开关/弹窗/文件 IO %s" % bad,
       "本插件只做『保持播放 + 单一音频源』，不需要任何配置")

# D4 不许 seek（保持播放不负责进度）
ok("seekToTime" not in code, "D4 不 seek",
   "seek 属于播放控制，不属于保持播放")

# D5 后台任务必须配对 end（泄漏会让系统杀进程）
#    ★ 实际调用名是 beginBackgroundTaskWithName:（带 expirationHandler 参数），
#      早期判据写 beginBackgroundTaskWithExpirationHandler:（不存在这个 API）→ 恒 False。
#    ★★ 不能用 `"endBackgroundTask" in code` 这种泛词判据：
#       `beginBackgroundTaskWithName:` 本身就含这个子串 → 永远为真 → 判据失效。
#       必须锚到 DYEndBgTask **函数体**里有没有真的调用那个 selector。
ok("beginBackgroundTaskWithName" in code, "D5 有 beginBackgroundTaskWithName",
   "没有后台任务 → 切小窗后系统很快回收进程")
ok("expirationHandler" in code, "D5b 有 expirationHandler",
   "没有过期回调 → 后台任务超时会被系统直接杀，没机会收尾")
endbg = body_of(code, "DYEndBgTask")
if endbg:
    ok("endBackgroundTask" in endbg,
       "D5d DYEndBgTask 体内真的调 endBackgroundTask",
       "只 begin 不 end → 后台任务泄漏 → 被系统强杀")
else:
    # 函数体找不到（被改名/删除）→ 也算违规：没有收尾函数就是泄漏
    # ★ 不用「找不到函数体」这种判据名：反向用例注入改名后，
    #   被拦的是这条本身，而不是 D5d → 会报「被代答」。
    #   直接在这里判「找不到 = 违规」，判据名与违规内容一一对应。
    ok(False, "D5d DYEndBgTask 体内真的调 endBackgroundTask",
       "DYEndBgTask 函数体不存在（被改名或删除）→ 后台任务无人收尾")

# ============================================================
# E 组：注入配置
# ============================================================
print("\n[E] 注入配置")

plist = open(PLIST, encoding='utf-8').read()
ok("com.ss.iphone.ugc.Aweme" in plist, "E1 plist 限定只注入抖音",
   "不限 Bundle 会注入所有进程 → 其它 App 也被改")
ok("Filter" in plist, "E1b plist 有 Filter")

# ============================================================
# 汇总
# ============================================================
print("\n" + "=" * 66)
if errors:
    print("✗ %d 项未通过 / 共 %d 项：" % (len(errors), checks))
    for e in errors:
        print("   ·", e)
    sys.exit(1)
print("✓ 源码闸门全过（%d 项）" % checks)
