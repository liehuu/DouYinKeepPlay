// DouYinKeepPlay.dylib v16 — 抖音小窗/后台播放保持（VC 层 pause 拦截 + 单一音频源强制）
//
// ★★★ v16 修复（用户实测：卸载本插件后「小窗切下一条视频仍留有上一条的声音」消失）：
//   现象：小窗里点 ±10 秒切到下一条视频 → 新视频在放，**上一条的声音还在响**。
//   根因（v15 结构缺陷，非推理，代码位置可核）：
//     ① DYEnterBackgroundKeepAlive() 在 WillResignActive/DidEnterBackground 时
//        把当时的播放器快照写进 gCandidates（切小窗那一刻 = **旧视频**的播放器）；
//     ② DYRecoverTick() 每 0.2 秒对 gCandidates 里每个「暂停了的」调用 DYPlay，
//        跑满 40 tick = **8 秒**；gCandidates 在这 8 秒内**从不重算** ——
//        它只在 DYEnterBackgroundKeepAlive 里赋值，而切视频不触发那个函数；
//     ③ 用户在这 8 秒内点 ±10 秒 → 抖音 pause 旧播放器、新建/切换播放器播新视频
//        → 但下一 tick 又把**旧播放器** DYPlay 回来（它在新候选里、被判为暂停）
//        → 新视频 + 旧视频同时发声。
//   2.1-7 的 DYSwitchFeed 里有 DYKeepStopRecover() 专治这个（源码注释：
//   「新视频在放、旧视频声音一起响」），v15 独立版没有「切视频」这个概念，
//   所以整段防护丢失。
//
//   v16 修法（三层，都是「让当前该响的那一路唯一」）：
//     ① **轮询动态重算**：DYRecoverTick 每 tick 从 gPlayers 按
//        gPlayerLastActive 重算 newest，不再用固定 gCandidates。
//        切视频后新播放器 play → 时间戳最新 → 立即成为 newest → 旧的不再被 play。
//     ② **每 tick 停旧**：非 newest 且未暂停的，用 per-class orig pause 停掉。
//        这样即使抖音自己没停旧播放器，本插件也会在 0.2 秒内收掉。
//     ③ **play 事件立即停旧**：DYPlayerPlayImpl 里一旦发现「这个 player 开始播放
//        且比已知 newest 更新」→ 立刻停掉其他所有在响的播放器 + 把候选收成它自己。
//        不必等下一个 tick，切视频瞬间就只剩一路。
//   ★ 注意：这三条都只在「保持播放生效中（离前台）」时动作，
//     回前台后一切交还抖音（gAppNonActive=NO → 轮询不跑）。
//
// v10 诊断版实测（用户回传双弹窗）确认关键事实：
//   - 底层播放器 hook 到 3 个：BDSimMediaPlayer / ALMSysPlayerWrapper /
//     ALMOwnPlayerWrapper（ALM 系 = 抖音 feed 视频真实底层播放器，conform IESVideoPlayerProtocol）
//   - 业务状态机 hook 到 4 个：AWEDPlayerFeedPlayerViewController /
//     AWEPlayVideoViewController / AWEPlayVideoExtraAbilityViewController /
//     AWEAwemePlayVideoViewController（feed 视频的真正业务控制器，conform AWEAwemePlayVideoProtocol）
//   - 轮询恢复"恢复 1 个播放器 (tick 2)" = 只恢复了底层 ALM 播放器，
//     VC 的 playState 没同步 → 视频在放但 UI 显示 ▶、锁屏按"暂停态"应答
//
// v10 根因复盘：切小窗时抖音的暂停入口在 VC 层（AWEPlayVideoViewController.pause）——
// 它既置 playState=暂停、又调底层 pause。v9/v10 只在底层"轮询 play 回来"，
// VC playState 永远停在暂停 → 状态分裂。v10 强制的 setEnableBackgroundPlay:YES
// 是空钩（业务不调这些开关），无效。
//
// v13 策略：回到 v11 验证有效的拦截逻辑（用户实测 v11 小窗 ❚❚ 正常），
// 并关闭诊断弹窗（DYDIAG=0 纯净版）。直接拦截 VC 层 pause
// （协议签名换 AWEAwemePlayVideoProtocol 的 pause [B16@0:8] 返回 BOOL，
// 与底层播放器 void pause 不同，分开 map）：
//   - 离前台（resignActive 后 <2s）的自动暂停 → 拦截（返回 YES，
//     playState 与底层播放器都不动，整条链路状态自洽 → UI ❚❚、底层继续响）
//   - 前台 / 离前台 2s 后用户操作 → 放行（切视频不崩）
//   - 底部轮询恢复 + 停旧保新保留（兜底：离前台后底层的其他暂停路径）
//   - 注：v12 引入的"近期触摸区分锁屏"改动已回退（用户反馈 v12 多个视频
//     声音重现，回退到 v11 稳定逻辑）
//
// v14 修复（用户实测反馈）：前台手动暂停视频后切小窗，视频自动开始播放，
// 已暂停状态未被保持。根因：DYUserTouchedRecently() 的"距最后触摸 <2s"
// 判据（v9 引入，区分"小窗切换应恢复"与"锁屏/久置不恢复"）无法区分
// "小窗切换"与"用户刚手动暂停后切小窗"——暂停按钮点击本身就是触摸，
// 切小窗手势同样 <2s → 被误判为小窗切换 → 轮询 DYPlay 把用户主动暂停的
// 播放器复活。v12 曾试图用触摸区分锁屏，引入多视频声音重现回归被回退，
// 该缺陷遗留至 v13。
// 修法（v14）：新增 gUserPausedAt 状态位——
//   - hook_dyn_vcPause 在"非离前台 2s 内自动暂停"的放行路径置位
//     （= 用户主动暂停：前台点暂停按钮 / 离前台 2s 后的暂停）
//   - DYTouchPlayer（底层 play / setRate: rate>0 播放动作）清除
//   - DidBecomeActive（回前台）清除
//   - DYEnterBackgroundKeepAlive 恢复判据：recover = touched && !gUserPausedAt
// v11 验证有效部分（停旧保新、候选单选、VC.pause 2s 拦截窗）原样保留，
// 不重走 v12 触摸区分路线，规避其回归。
//
// v15 修复（实机崩溃，Aweme-2026-10-19-110735.ips 铁证）：
//   现象：刷抖音不定时闪退，主线程 EXC_BAD_ACCESS / SIGSEGV
//         KERN_PROTECTION_FAILURE at STACK GUARD。
//   崩溃栈：511 帧 hook_dyn_vcPause 自我递归（帧 9~510 交替出现
//         dylib offset 0x7364 函数入口 / 0x73a0 调 orig 处，中间为 hook
//         trampoline 无名帧），直到栈溢出撞保护页。
//   根因：DYOrigVCPauseFor 靠 NSStringFromClass([self class]) 查 map 取 orig。
//         父类 A 先被 hook，A.pause 已换成 trampoline；随后枚举到子类 B 时，
//         class_getInstanceMethod(B, pause) 解析到的是被 hook 过的 A 实现，
//         于是 MSHookMessageEx 为 B 存下的 orig 就是那条 trampoline。
//         B 实例一次 pause → hook(self=B) → 查表("B") → trampoline_A
//         → hook(self=B) → …… 无限递归。
//         （底层播放器 pause/play/setRate: 同样有父子类交叉递归风险，v5 起潜伏）
//   修法（两道）：
//     1) per-class orig（根治）：新增 gVCOrigByClass 字典（Class 为 key，不走
//        NSStringFromClass），hook 包装器只从 imp_implementationWithBlock 的
//        block 捕获里取本类 orig，彻底不查表 → 无交叉可能。
//     2) 同线程同类重入闸（兜底）：gRecursing 标记，重入直接调 orig 不再走逻辑。
//   另：hook 前 method_getTypeEncoding 校验签名（VC.pause 必须 B@:），
//   不匹配的类跳过，防把 void 实现当 BOOL 读返回值。
//
// 技术要点（沿用）：
//   - 抖音底层播放器 = ALM 系（ALMOwn/SysPlayerWrapper），业务控制 = PlayVideoViewController
//   - 动态 selector 调用走 objc_msgSend 显式转换（clang 不允许 id 上调未声明 selector）
//   - Substrate Filter 限定只注入抖音进程（DouYinKeepPlay.plist: com.ss.iphone.ugc.Aweme）

#define DYDIAG 0

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/lock.h>

#pragma mark - Substrate API（运行时解析）

typedef void (*DYImpVoid)(id, SEL);
typedef void (*DYImpFloat)(id, SEL, float);
typedef void (*DYImpEvent)(id, SEL, UIEvent *);
typedef void (*DYImpAddObs)(id, SEL, id, SEL, NSNotificationName, id);
typedef BOOL (*DYImpBool)(id, SEL);            // VC 层 pause（AWEAwemePlayVideoProtocol 返回 BOOL）

static void (*pMSHookMessageEx)(Class, SEL, void *, void **);
static void DYResolveSubstrate(void) {
    void *h = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/ellekit.dylib", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/substrate.dylib", RTLD_NOW);
    if (h) pMSHookMessageEx = (void (*)(Class, SEL, void *, void **))dlsym(h, "MSHookMessageEx");
    if (!pMSHookMessageEx) {
        pMSHookMessageEx = (void (*)(Class, SEL, void *, void **))dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    }
    NSLog(@"[DouYinKeepPlay] substrate MSHookMessageEx: %@", pMSHookMessageEx ? @"可用" : @"不可用");
}

#pragma mark - 全局状态

static NSDate *gLastTouchAt = nil;                  // 最近一次触摸事件（区分用户主动/自动暂停）
static BOOL gAppNonActive = NO;                     // app 已离前台（resign/enterBackground 置位，v7 拦截门）
static BOOL gShouldRecover = NO;                    // v9：本次进后台是否恢复播放（小窗切换=YES，锁屏/久置=NO）
static NSHashTable *gPlayers = nil;                 // player 实例弱注册表（任何被 hook 的类）
static NSMutableArray *gCandidates = nil;           // 进后台时的候选播放器（强引用保活）
static UIBackgroundTaskIdentifier gBgTask;          // 后台任务 ID（DYCtor 初始化）
static NSInteger gRecoverTicks = 0;                 // 轮询计数
static BOOL gRecoverRunning = NO;                   // 轮询链是否在跑（防重复启动）
static BOOL gHooksInstalled = NO;                   // hooks 是否安装成功

// v5 侦察数据
static NSMutableDictionary *gOrigPauseMap = nil;    // 类名(NSString) -> orig pause 指针(NSValue)
static NSMutableDictionary *gOrigSetRateMap = nil;  // 类名(NSString) -> orig setRate: 指针(NSValue)
static NSMutableDictionary *gOrigPlayMap = nil;     // 类名(NSString) -> orig play 指针(NSValue)（v8）
static NSMapTable *gPlayerLastActive = nil;         // v8：player(weak) -> 最近播放动作时间(NSDate)
static NSMutableArray *gHookedClasses = nil;        // 已 hook 的类名列表
static NSMutableArray *gLifecycleObservers = nil;   // 注册了生命周期通知的观察者描述
static NSMutableSet *gReportedObservers = nil;      // 去重

// v11：业务 VC 类列表（实现 AWEAwemePlayVideoProtocol / AWEAwemePlayVideoTrackProtocol，
// 诊断报告展示 + VC.pause 拦截统计用）
static NSMutableArray *gBgStateClasses = nil;              // 已 hook 业务 VC 的类名列表

// v11：VC 层 pause/play 拦截（AWEAwemePlayVideoProtocol 的 pause/play 返回 BOOL，
// 与底层播放器 void pause 不同，需独立 map 存储 orig）
static NSMutableDictionary *gVCPauseMap = nil;             // 类名 -> orig VC pause(BOOL) 指针（v15 起仅作诊断计数）
static NSDate *gResignAt = nil;                            // v11：最近一次离前台时间（区分自动/手动暂停）
static NSDate *gUserPausedAt = nil;                        // v14：用户主动暂停时刻（VC.pause 放行路径置位，播放动作/回前台清除）

// v15 递归防护：重入深度计数（同一线程）
// 崩溃 ips：511 帧自我递归撞栈保护页。根治靠 per-class orig 捕获；
// 这里只做最后保险，且阈值放到 8 层——父子类正常继承链会合法地穿过
// 2~3 层（B.block → A.block → 真 orig），阈值太低会把用户手动暂停吞掉。
static __thread int gHookReentry = 0;
#define DY_REENTRY_LIMIT 8

// v6 线程安全：全局锁保护所有共享可变状态。
// 约定：锁内只做容器读写/状态判断，绝不调用外部对象 selector（防重入死锁）。
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

/// 近期（2s 内）有触摸 → 判定为用户刚操作过（v9：仅用于区分
/// "小窗切换"（手势刚结束，应恢复播放）与"锁屏/久置"（不应恢复））
static BOOL DYUserTouchedRecently(void) {
    BOOL recent = NO;
    os_unfair_lock_lock(&gLock);
    if (gLastTouchAt) recent = (-[gLastTouchAt timeIntervalSinceNow]) < 2.0;
    os_unfair_lock_unlock(&gLock);
    return recent;
}

/// v9 起 pause/setRate: 全部放行，播放保持改为轮询恢复，
/// DYAppIsActive（v7 拦截门）已不再需要，随之移除。
/// gAppNonActive 保留（通知里维护，Console/后续扩展可读）。
/// 播放动作（底层 play / setRate: rate>0）：刷新 player 活跃时间，
/// 并 v14 清除用户主动暂停标记——有播放动作即解除暂停态
static void DYTouchPlayer(id p) {
    if (!p) return;
    os_unfair_lock_lock(&gLock);
    gUserPausedAt = nil;  // v14：播放动作 → 用户主动暂停状态解除
    if (gPlayerLastActive) [gPlayerLastActive setObject:[NSDate date] forKey:p];
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - 诊断工具（DYDIAG）

#if DYDIAG
static BOOL gDiagAlertedPause = NO;
static BOOL gDiagAlertedRecover = NO;
static BOOL gDiagAlertedReport = NO;

static UIViewController *DYTopViewController(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *keyWindow = nil;
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
            }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) {
        for (UIWindow *w in app.windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
    }
    if (!keyWindow && app.windows.count > 0) keyWindow = app.windows.firstObject;
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void DYShowAlert(NSString *title, NSString *msg) {
    UIViewController *vc = DYTopViewController();
    if (!vc) { NSLog(@"[DouYinKeepPlay][Diag] 无可见 VC，Alert 跳过: %@", title); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

static void DYTryShowAlert(NSString *title, NSString *msg, int retry) {
    UIViewController *vc = DYTopViewController();
    if (vc) {
        DYShowAlert(title, msg);
    } else if (retry > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ DYTryShowAlert(title, msg, retry - 1); });
    }
}

/// 5s 后报告侦察结果（hook 的类 + 生命周期观察者）
static void DYScheduleReportAlert(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gDiagAlertedReport) return;
        gDiagAlertedReport = YES;
        NSMutableString *clsList = [NSMutableString string];
        for (NSString *c in [gHookedClasses subarrayWithRange:NSMakeRange(0, MIN(10, gHookedClasses.count))]) {
            [clsList appendFormat:@"  %@\n", c];
        }
        NSMutableString *obsList = [NSMutableString string];
        for (NSString *o in [gLifecycleObservers subarrayWithRange:NSMakeRange(0, MIN(10, gLifecycleObservers.count))]) {
            [obsList appendFormat:@"  %@\n", o];
        }
        // v12：业务 VC hook 结果（含 VC.pause 拦截——切小窗拦/锁屏放）
        NSMutableString *bgList = [NSMutableString string];
        if (gBgStateClasses.count == 0) {
            [bgList appendString:@"  (无！VC 未枚举到)\n"];
        } else {
            for (NSString *c in [gBgStateClasses subarrayWithRange:NSMakeRange(0, MIN(10, gBgStateClasses.count))]) {
                [bgList appendFormat:@"  %@\n", c];
            }
        }
        NSString *msg = [NSString stringWithFormat:
            @"substrate: %@\n"
            @"── 底层播放器 ──\n"
            @"hook Player 类: %lu 个\n%@\n"
            @"── 业务VC(v12护栏) ──\n"
            @"hook 业务VC: %lu 个\n"
            @"VC.pause 拦截: %lu 个\n%@\n"
            @"── 生命周期观察者 ──\n"
            @"%@",
            pMSHookMessageEx ? @"可用" : @"不可用",
            (unsigned long)gHookedClasses.count, clsList,
            (unsigned long)gBgStateClasses.count,
            (unsigned long)gVCPauseMap.count, bgList,
            obsList];
        DYTryShowAlert(@"DouYinKeepPlay v12 诊断报告", msg, 6);
        NSLog(@"[DouYinKeepPlay][Diag] === 诊断报告 ===\n%@", msg);
    });
}
#endif

#pragma mark - 机制 3：后台轮询恢复

static void DYRecoverTick(void);

// 前向声明（DYEnterBackgroundKeepAlive 停旧播放器时要用，定义在后面 hook 区）
static DYImpVoid DYOrigPauseFor(id self);
static DYImpFloat DYOrigSetRateFor(id self);
static DYImpVoid DYOrigPlayFor(id self);

// v16 新增前向声明：DYSilenceAllBut 用到的探测/恢复函数定义在更后面
static BOOL DYIsPaused(id p);
static BOOL DYPlay(id p);

/// ★★★ v16 新增：从注册表里算出「当前该响的那一路」。
///   判据 = 最近一次播放动作（play / setRate:>0）时间最晚的那个实例。
///
/// ★ 为什么不能沿用 gCandidates：它只在 DYEnterBackgroundKeepAlive 里赋值，
///   而那个函数只在 WillResignActive / DidEnterBackground 时被调 ——
///   **切视频不触发它**。于是切小窗那一刻快照下来的旧播放器会一直留在候选里，
///   轮询每 0.2 秒把它 play 回来 → 新旧两路同时发声（v15 的真实缺陷）。
///   这里改成每次现算，切视频后新播放器一 play 就立刻成为 newest。
///
/// ★ 只在锁内取快照，探测（DYIsPaused 等外部 selector）放锁外 —— 与既有约定一致。
/// ★ 返回 +1 强引用的数组（调用方负责在 ARC 下自然释放）。
static NSArray *DYCurrentPlayersSnapshot(void) {
    os_unfair_lock_lock(&gLock);
    NSArray *snap = gPlayers ? [gPlayers allObjects] : nil;
    os_unfair_lock_unlock(&gLock);
    return snap;
}

/// 取「最近活跃时间」最晚的播放器（= 当前该发声的那一路）。
/// 没有任何活跃记录时返回 nil（此时不做任何停旧/恢复动作，避免误伤）。
static id DYNewestPlayerIn(NSArray *snap) {
    if (snap.count == 0) return nil;
    id newest = nil;
    NSDate *newestAt = nil;
    os_unfair_lock_lock(&gLock);
    if (gPlayerLastActive) {
        for (id p in snap) {
            NSDate *d = [gPlayerLastActive objectForKey:p];
            if (!d) continue;
            if (!newestAt || [d compare:newestAt] == NSOrderedDescending) {
                newestAt = d;
                newest = p;
            }
        }
    }
    os_unfair_lock_unlock(&gLock);
    return newest;
}

/// ★★★ v16 核心：确保「只有 newest 这一路在响」。
///   对每个非 newest 且未暂停的播放器，用 per-class 真 orig 调一次 pause。
///   被自己 pause 掉的旧播放器不会再被轮询复活（v16 的轮询只 play newest）。
///
/// ★ 为什么必须用 orig 而不是直接 [p pause]：直接调会走进 hook → 触发
///   DYRegisterPlayerInstance / DYTouchPlayer（把刚停掉的那路重新标成 newest，
///   等于自己把自己拧回去）。走 orig 是「静默停掉」，不产生新状态。
/// ★ 只在「离前台且保持播放生效中」调用 —— 前台绝不主动停任何播放器。
/// 返回停掉的个数。
static NSUInteger DYSilenceAllBut(id newest, NSArray *snap) {
    if (snap.count == 0) return 0;
    NSUInteger stopped = 0;
    for (id p in snap) {
        if (!p || p == newest) continue;
        @try {
            if (DYIsPaused(p)) continue;      // 已经停了，不重复动作
            DYImpVoid orig = DYOrigPauseFor(p);
            if (!orig) continue;
            orig(p, @selector(pause));        // 走真 orig：不触发 hook、不改 newest
            stopped++;
        } @catch (NSException *e) { /* 单个实例失败不影响其它 */ }
    }
    return stopped;
}

static void DYEndBgTask(void) {
    UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    os_unfair_lock_lock(&gLock);
    if (gBgTask != UIBackgroundTaskInvalid) {
        task = gBgTask;
        gBgTask = UIBackgroundTaskInvalid;
    }
    os_unfair_lock_unlock(&gLock);
    if (task != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:task];
    }
}

/// 探测 player 是否处于暂停态（兼容 IESVideoPlayer 协议各种属性名）
/// 全部走 objc_msgSend 显式调用，避开 clang 对 id 类型未声明 selector 的静态检查
static BOOL DYIsPaused(id p) {
    @try {
        if ([p respondsToSelector:@selector(isPaused)])
            return ((BOOL (*)(id, SEL))objc_msgSend)(p, @selector(isPaused));
        if ([p respondsToSelector:@selector(paused)])
            return ((BOOL (*)(id, SEL))objc_msgSend)(p, @selector(paused));
        if ([p respondsToSelector:@selector(isPlaying)])
            return !((BOOL (*)(id, SEL))objc_msgSend)(p, @selector(isPlaying));
        if ([p respondsToSelector:@selector(isPlayFinished)])
            return ((BOOL (*)(id, SEL))objc_msgSend)(p, @selector(isPlayFinished));
    } @catch (NSException *e) { /* 忽略 */ }
    return YES;  // 探测不到 → 当作暂停（恢复动作幂等无害）
}

/// 恢复播放（兼容 IESVideoPlayer 协议，同样走 objc_msgSend）
static BOOL DYPlay(id p) {
    @try {
        if ([p respondsToSelector:@selector(play)]) {
            ((void (*)(id, SEL))objc_msgSend)(p, @selector(play));
            return YES;
        }
        if ([p respondsToSelector:@selector(resume)]) {
            ((void (*)(id, SEL))objc_msgSend)(p, @selector(resume));
            return YES;
        }
    } @catch (NSException *e) { /* 忽略 */ }
    return NO;
}

static void DYRecoverTick(void) {
    // 锁内取运行态，锁外探测恢复（不在锁内调用外部 selector）
    BOOL running = NO;
    BOOL shouldRecover = NO;
    NSInteger tick = 0;
    os_unfair_lock_lock(&gLock);
    running = gRecoverRunning;
    shouldRecover = gShouldRecover;  // v9：锁屏/久置场景不恢复
    tick = ++gRecoverTicks;
    os_unfair_lock_unlock(&gLock);
    if (!running) return;

    // v9：无需恢复（锁屏/久置）→ 立即收尾，交还控制权
    if (!shouldRecover) {
        BOOL shouldStop = NO;
        os_unfair_lock_lock(&gLock);
        if (gRecoverRunning) { gRecoverRunning = NO; shouldStop = YES; }
        os_unfair_lock_unlock(&gLock);
        if (shouldStop) {
            DYEndBgTask();
            NSLog(@"[DouYinKeepPlay] 无需恢复播放（锁屏/久置场景），交还控制权");
        }
        return;
    }

    // ★★★ v16：每个 tick 都从注册表现算「当前该响的那一路」，不再用固定候选。
    //
    //   v15 的写法是 `[gCandidates copy]` 然后逐个 play 回来。gCandidates 只在
    //   DYEnterBackgroundKeepAlive 里赋值一次（切小窗那一刻 = 旧视频的播放器），
    //   之后 8 秒内不再更新 —— 用户在窗口内切视频，新视频开始播，但下一 tick
    //   又把**旧播放器** play 回来 → 双路音频（用户实测：切下一条仍留上一条声音）。
    //
    //   v16 改成：
    //     · 现算 newest（最近播放动作最晚的那个）→ 只有它允许 play；
    //     · 其余在响的用真 orig pause 静默停掉（DYSilenceAllBut）。
    //   切视频后新播放器一 play，时间戳就是最新 → 立即成为唯一发声源，
    //   旧的一律在 0.2 秒内被收掉，不依赖抖音自己有没有停旧。
    NSArray *snapshot = DYCurrentPlayersSnapshot();
    id newest = DYNewestPlayerIn(snapshot);

    NSUInteger recovered = 0;
    NSUInteger silenced = 0;
    if (newest) {
        // 只恢复 newest 这一个（防止复活旧音频）
        if (DYIsPaused(newest)) {
            if (DYPlay(newest)) recovered++;
        }
        // 然后收掉所有非 newest 但仍在响的
        silenced = DYSilenceAllBut(newest, snapshot);
    }

    if (recovered || silenced) {
        NSLog(@"[DouYinKeepPlay] 轮询: 恢复 %lu 个 / 静默旧音频 %lu 个 (tick %ld, 注册 %lu)",
              (unsigned long)recovered, (unsigned long)silenced,
              (long)tick, (unsigned long)snapshot.count);
    }
#if DYDIAG
    if (recovered && !gDiagAlertedRecover) {
        gDiagAlertedRecover = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            DYTryShowAlert(@"DouYinKeepPlay 轮询恢复",
                           [NSString stringWithFormat:@"恢复 %lu 个播放器\n(tick %ld)",
                            (unsigned long)recovered, (long)tick], 3);
        });
    }
#endif

    // ★★★ v16：轮询窗口从 8 秒（40 tick）延长到整个后台期。
    //
    //   v15 的 40 tick 是为「切小窗瞬间那一次暂停」设计的兜底窗口。
    //   但 v16 把「停旧」也挂在这个轮询上 —— 用户在小窗里**连续**切好几条视频，
    //   每次切换都需要一次「收掉旧音频」，8 秒后轮询就停了，之后再切就没人收旧
    //   → 又回到"上一条声音还在"。
    //
    //   改成：只要还离前台（gAppNonActive）且标记未清，就一直跑，间隔仍 0.2 秒
    //   （保证切视频后 0.2 秒内收干净、听感无残留）。
    //   上限 3000 tick = 10 分钟，只作防跑飞的保险（正常回前台会立刻收尾）。
    //   ★ 0.2 秒一次、每次只读弱表 + 最多几次 isPaused 探测，功耗可忽略。
    #define DY_RECOVER_MAX_TICKS 3000
    if (tick < DY_RECOVER_MAX_TICKS) {
        BOOL stillAway = NO;
        os_unfair_lock_lock(&gLock);
        stillAway = gAppNonActive;   // 回前台了就没必要继续轮询（下面立刻收尾）
        os_unfair_lock_unlock(&gLock);
        if (!stillAway) {
            BOOL shouldStop = NO;
            os_unfair_lock_lock(&gLock);
            if (gRecoverRunning) { gRecoverRunning = NO; shouldStop = YES; }
            os_unfair_lock_unlock(&gLock);
            if (shouldStop) {
                DYEndBgTask();
                NSLog(@"[DouYinKeepPlay] 已回前台，轮询收尾");
            }
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ DYRecoverTick(); });
    } else {
        BOOL shouldStop = NO;
        os_unfair_lock_lock(&gLock);
        if (gRecoverRunning && gRecoverTicks >= DY_RECOVER_MAX_TICKS) {
            gRecoverRunning = NO;
            shouldStop = YES;
        }
        os_unfair_lock_unlock(&gLock);
        if (shouldStop) {
            DYEndBgTask();
            NSLog(@"[DouYinKeepPlay] 轮询达到上限（%d tick）结束", DY_RECOVER_MAX_TICKS);
        }
    }
}

/// 进入非活跃：抢占后台执行时间 + 快照候选 + 启动轮询
/// v9：pause 已全部放行，这里只做"停旧保新兜底 + 决定是否恢复播放"。
/// gShouldRecover = 距最后触摸 < 2s（小窗切换特征 → 恢复）；
/// 锁屏/久置（无近期触摸）→ 不恢复，锁屏控制权完全交还用户。
static void DYEnterBackgroundKeepAlive(void) {
    // v11：不再主动 DYActivateBgState()——v10 诊断确认强制 setEnableBackgroundPlay:YES
    // 是空钩（业务不调这些开关），且主动调 setter 可能有副作用（音频会话切换/降音量）。
    // 现在根因修复点是 VC.pause 拦截（已 hook），这里只保留底层"停旧保新 + 轮询恢复"兜底。

    // beginBackgroundTask 是外部调用放锁外；gBgTask 判断/赋值走锁，
    // 防 expirationHandler（系统队列）并发把 gBgTask 置 invalid 后重复 begin
    BOOL needBegin = NO;
    os_unfair_lock_lock(&gLock);
    if (gBgTask == UIBackgroundTaskInvalid) needBegin = YES;
    os_unfair_lock_unlock(&gLock);
    if (needBegin) {
        UIBackgroundTaskIdentifier t =
            [[UIApplication sharedApplication]
             beginBackgroundTaskWithName:@"DouYinKeepPlay"
             expirationHandler:^{
            NSLog(@"[DouYinKeepPlay] 后台任务即将过期");
            os_unfair_lock_lock(&gLock);
            gRecoverRunning = NO;
            os_unfair_lock_unlock(&gLock);
            DYEndBgTask();
        }];
        BOOL leak = NO;
        os_unfair_lock_lock(&gLock);
        if (gBgTask == UIBackgroundTaskInvalid) {
            gBgTask = t;
            NSLog(@"[DouYinKeepPlay] beginBackgroundTask: %lu", (unsigned long)t);
        } else {
            leak = YES;  // 极端竞态：begin 期间已被 end，补 end 刚拿的 task 防泄漏
        }
        os_unfair_lock_unlock(&gLock);
        if (leak) [[UIApplication sharedApplication] endBackgroundTask:t];
    }
    // 锁内 allObjects 拿强引用快照（数组元素 retain），锁外探测
    NSArray *snapshot = nil;
    id newest = nil;  // v8：最近播放动作的 player = 当前该响的
    os_unfair_lock_lock(&gLock);
    snapshot = [gPlayers allObjects];
    for (id p in snapshot) {
        NSDate *d = [gPlayerLastActive objectForKey:p];
        if (d && (!newest || [d compare:[gPlayerLastActive objectForKey:newest]] == NSOrderedDescending)) {
            newest = p;
        }
    }
    os_unfair_lock_unlock(&gLock);

    // v8：停旧保新——仍在发声的非最新播放器，用 orig pause 真正停掉
    // （它们的 pause 之前被我们拦截没停成，就是多路音频的来源）
    // v16：复用 DYSilenceAllBut（与轮询/play 事件走同一套逻辑，行为一致）
    NSUInteger stopped = DYSilenceAllBut(newest, snapshot);

    // v8：候选只保留最新的一个（轮询恢复也只恢复它，防止复活旧音频）
    NSMutableArray *arr = [NSMutableArray array];
    if (newest) {
        @try { if (DYIsPaused(newest) || [newest respondsToSelector:@selector(play)]) [arr addObject:newest]; }
        @catch (NSException *e) { /* 忽略 */ }
    }

    BOOL start = NO;
    BOOL recover = DYUserTouchedRecently();  // v9：小窗切换（刚操作过）才恢复
    os_unfair_lock_lock(&gLock);
    // v14：用户主动暂停过（VC.pause 前台放行置位，期间无播放动作）→
    // 尊重暂停态，切小窗不恢复（修复"手动暂停后切小窗自动播放"）
    if (gUserPausedAt) recover = NO;
    // v16：gCandidates 现在只作「诊断/日志」用途，轮询不再读它
    // （轮询每 tick 现算 newest，见 DYRecoverTick）。这里只保留 newest 一个，
    // 语义 = 进后台那一刻认为「唯一该响的那一路」，与旧版行为等价。
    gCandidates = arr;
    gShouldRecover = recover;  // v9：锁屏/久置 → NO，轮询首 tick 即收尾
    if (!gRecoverRunning) {
        gRecoverRunning = YES;
        gRecoverTicks = 0;
        start = YES;
    }
    NSUInteger registered = gPlayers.count;
    os_unfair_lock_unlock(&gLock);

    NSLog(@"[DouYinKeepPlay] 候选播放器: %lu 个（注册表 %lu，停掉旧音频 %lu 个，恢复播放=%d）",
          (unsigned long)arr.count, (unsigned long)registered, (unsigned long)stopped, recover);
    if (start) DYRecoverTick();
}

#pragma mark - 动态 hook：player 类的 pause / setRate:

// v15：DYRegisterPlayerInstance 定义在下方（v11 原位），这里先前置声明
static void DYRegisterPlayerInstance(id p);

/// 从 map 取 orig 指针（按 self 的类名查）
/// v15 注意：仅用于"停旧保新"主动停旧播放器。正常 hook 链已改为 per-class
/// block 捕获（见 DYEnumerateAndHookPlayers），本函数可能取到父类 trampoline，
/// 但 trampoline 会在父类 block 处收口，不会递归。
static DYImpVoid DYOrigPauseFor(id self) {
    NSValue *v = gOrigPauseMap[NSStringFromClass([self class])];
    return v ? (DYImpVoid)[v pointerValue] : NULL;
}

static DYImpFloat DYOrigSetRateFor(id self) {
    NSValue *v = gOrigSetRateMap[NSStringFromClass([self class])];
    return v ? (DYImpFloat)[v pointerValue] : NULL;
}

static DYImpVoid DYOrigPlayFor(id self) {
    NSValue *v = gOrigPlayMap[NSStringFromClass([self class])];
    return v ? (DYImpVoid)[v pointerValue] : NULL;
}

/// v15：底层播放器三个 hook 的公共实现（per-class orig，见安装处 block 捕获）
/// v9：pause 全部放行（真暂停）——v5~v8 的"拦截 pause"会造成播放器真实状态与
/// 抖音业务 UI 状态分裂（小窗显示 ▶ 实际在放、锁屏暂停命令被吞），v9 起播放保持
/// 改为"放行 + 轮询快速恢复"，让播放器真实经历 暂停→播放，UI 跟着回到播放态。
static void DYPlayerPauseImpl(id self, SEL _cmd, DYImpVoid orig) {
    if (gHookReentry >= DY_REENTRY_LIMIT) {  // v15：超深链直接放行，绝不继续展开
        if (orig) orig(self, _cmd);
        return;
    }
    gHookReentry++;
    DYRegisterPlayerInstance(self);
    if (orig) orig(self, _cmd);
    else NSLog(@"[DouYinKeepPlay] 警告: %@ pause orig 未找到", NSStringFromClass([self class]));
    gHookReentry--;
}

/// v9：setRate: 全部放行（rate<=0 真暂停）；rate>0 = 播放动作，刷新时间戳
static void DYPlayerSetRateImpl(id self, SEL _cmd, float rate, DYImpFloat orig) {
    if (gHookReentry >= DY_REENTRY_LIMIT) {
        if (orig) orig(self, _cmd, rate);
        return;
    }
    gHookReentry++;
    DYRegisterPlayerInstance(self);
    if (rate > 0.0001f) DYTouchPlayer(self);
    if (orig) orig(self, _cmd, rate);
    else NSLog(@"[DouYinKeepPlay] 警告: %@ setRate: orig 未找到", NSStringFromClass([self class]));
    gHookReentry--;
}

/// v8/v9：play 只做"播放动作"记录 + 放行，不做任何拦截
/// （播放保持 = pause 放行 + 轮询恢复调 play，play 必须始终真实执行）
///
/// ★★★ v16 新增：play 一发生就「立即停旧」。
///   这是切视频时的第一道响应，不能只等下一个轮询 tick（0.2s 内可能有多次 play）。
///   做法：先刷新 self 的时间戳（成为 newest），再把其它仍在响的播放器静默停掉。
///
///   ★ 为什么不直接调 [other pause]：那会走进 hook → DYRegisterPlayerInstance /
///     DYTouchPlayer 把它重新标成最新 → 等于把刚停掉的又扶回 newest，自己拧自己。
///     走 per-class 真 orig 是静默停，不产生新状态（同轮询里的 DYSilenceAllBut）。
///
///   ★ 只在小窗/后台生效（gAppNonActive=YES）：前台由抖音自己管播放器生命周期，
///     我们一根手指都不伸 —— 前台乱停会把用户正在看的视频掐掉。
static void DYPlayerPlayImpl(id self, SEL _cmd, DYImpVoid orig) {
    if (gHookReentry >= DY_REENTRY_LIMIT) {
        if (orig) orig(self, _cmd);
        return;
    }
    gHookReentry++;
    DYRegisterPlayerInstance(self);
    DYTouchPlayer(self);   // 先让 self 成为 newest，再停其它

    // v16：小窗中一旦有新播放器开始播放 → 立刻收掉其它在响的
    BOOL away = NO;
    os_unfair_lock_lock(&gLock);
    away = gAppNonActive;
    os_unfair_lock_unlock(&gLock);
    if (away) {
        NSArray *snapshot = DYCurrentPlayersSnapshot();
        NSUInteger silenced = DYSilenceAllBut(self, snapshot);
        if (silenced) {
            NSLog(@"[DouYinKeepPlay] play 即停旧: %@（静默旧音频 %lu 路）",
                  NSStringFromClass([self class]), (unsigned long)silenced);
        }
    }

    if (orig) orig(self, _cmd);
    else NSLog(@"[DouYinKeepPlay] 警告: %@ play orig 未找到", NSStringFromClass([self class]));
    gHookReentry--;
}

/// v15：原实现靠 NSStringFromClass([self class]) 查 map 取 orig —— 父子类交叉时
/// 子类的 orig 实际是父类的 hook trampoline，形成无限递归（ips 铁证 511 帧）。
/// 现在每个类的 hook 包装器只从 imp_implementationWithBlock 的捕获里取本类 orig，
/// 不查表 → 子类调 trampoline_A 后由 blockA 用自己的真 orig 收口，递归必然终止。
/// gHookReentry 是最后一道保险：同线程重入直接吞掉（保持播放），绝不继续展开。
static BOOL DYVCPauseImpl(id self, SEL _cmd, DYImpBool orig) {
    if (gHookReentry >= DY_REENTRY_LIMIT) {
        // 极深链（理论上 per-class 捕获后不会发生）→ 切断，保持播放
        return YES;
    }
    gHookReentry++;

    BOOL block = NO;
    BOOL userPaused = NO;
    NSTimeInterval dt = 0;
    os_unfair_lock_lock(&gLock);
    if (gAppNonActive && gResignAt) {
        dt = -[gResignAt timeIntervalSinceNow];
        if (dt < 2.0) block = YES;
    }
    if (!block) {
        // v14：非"离前台 2s 内自动暂停"的 VC.pause = 用户主动暂停
        gUserPausedAt = [NSDate date];
        userPaused = YES;
    }
    os_unfair_lock_unlock(&gLock);

    BOOL result;
    if (block) {
        NSLog(@"[DouYinKeepPlay][VC] 拦截 VC.pause（离前台 %.2fs 自动暂停）-> 返回 YES 保持播放: %@",
              dt, NSStringFromClass([self class]));
        result = YES;  // 吞掉，playState 不变
    } else {
        if (userPaused) {
            NSLog(@"[DouYinKeepPlay][VC] 用户主动暂停（放行，标记 gUserPausedAt）: %@",
                  NSStringFromClass([self class]));
        }
        result = orig ? orig(self, _cmd) : NO;
    }

    gHookReentry--;
    return result;
}

/// v15：判断类是否**自己**声明了某 selector（不走继承链）。
/// class_getInstanceMethod 会顺着继承链返回父类方法，若据此去 hook，
/// 子类会被多包一层无意义的 trampoline，既增调用栈深度又干扰签名判断。
/// 用 class_copyMethodList 直接查自身方法表，语义精确。
static BOOL DYClassDeclaresSelector(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return NO;
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

/// 运行时枚举实现 AWEAwemePlayVideoProtocol / AWEAwemePlayVideoTrackProtocol 的类
/// （实为 feed 视频业务控制器，v10 诊断确认 AWEPlayVideoViewController 等 4 个），
/// 并 hook 其 pause（返回 BOOL）做根因拦截——喂 feed 视频暂停的唯一入口。
/// v15：改用 imp_implementationWithBlock 按类捕获 orig（根治父子类递归），
/// 并在 hook 前校验方法签名必须为 BOOL 无参（B@:），不匹配跳过。
static void DYHookBackgroundStateMachine(void) {
    if (!pMSHookMessageEx) return;
    Protocol *playProto = objc_getProtocol("AWEAwemePlayVideoProtocol");
    Protocol *trackProto = objc_getProtocol("AWEAwemePlayVideoTrackProtocol");

    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (num + 16));
    if (!classes) return;
    num = objc_getClassList(classes, num);

    NSInteger hooked = 0;
    NSInteger sigRejected = 0;
    for (int i = 0; i < num; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        BOOL playOk = playProto && class_conformsToProtocol(cls, playProto);
        BOOL trackOk = trackProto && class_conformsToProtocol(cls, trackProto);
        if (!playOk && !trackOk) continue;

        const char *cname = class_getName(cls);
        NSString *clsName = cname ? @(cname) : @"?";
        // 排除纯协议对象自身与 Swift 元数据类（_TtC 前缀）
        if ([clsName hasPrefix:@"_TtC"]) continue;

        SEL vcPauseSel = @selector(pause);
        // v15：只处理类自己声明了 pause 的（继承来的由父类那次 hook 覆盖，
        // 再包一层只会加深调用链，且签名可能来源于父类，判断失真）
        if (!DYClassDeclaresSelector(cls, vcPauseSel)) continue;
        Method m = class_getInstanceMethod(cls, vcPauseSel);
        if (!m) continue;

        // v15：签名校验——AWEAwemePlayVideoProtocol 的 pause 是 - (BOOL)pause，
        // 编码 "B16@0:8"。签名不符（void 或带参）一律跳过，否则按 BOOL 读返回值
        // 会拿到垃圾寄存器内容，调用方走错分支。
        const char *typeEnc = method_getTypeEncoding(m);
        if (!typeEnc || typeEnc[0] != 'B') {
            sigRejected++;
            NSLog(@"[DouYinKeepPlay][VC] 跳过签名不符的类: %@ (pause 编码=%s)",
                  clsName, typeEnc ? typeEnc : "null");
            continue;
        }

        // v15 核心：orig 用 block 捕获（per-class），不再靠类名查表 →
        // 子类即便拿到父类 trampoline，最终也由父类 block 用自己的真 orig 收口
        __block DYImpBool capturedOrig = NULL;
        id block = ^BOOL(id s, SEL c) {
            return DYVCPauseImpl(s, c, capturedOrig);
        };
        IMP newImp = imp_implementationWithBlock(block);
        if (!newImp) continue;

        void *origP = NULL;
        pMSHookMessageEx(cls, vcPauseSel, (void *)newImp, &origP);
        if (origP) {
            capturedOrig = (DYImpBool)origP;
            gVCPauseMap[clsName] = [NSValue valueWithPointer:origP];  // 仅诊断计数
            [gBgStateClasses addObject:clsName];
            hooked++;
            NSLog(@"[DouYinKeepPlay][VC] hook 业务VC: %@ (pause=%d, 编码=%s)",
                  clsName, class_respondsToSelector(cls, vcPauseSel), typeEnc);
        }
    }
    free(classes);
    gVCPauseMap = [gVCPauseMap copy];
    NSLog(@"[DouYinKeepPlay][VC] 共 hook %ld 个业务VC（per-class orig，签名不符跳过 %ld 个）",
          (long)hooked, (long)sigRejected);
}

/// 注册 player 实例到弱表（hook 到调用即注册，供轮询恢复用）
static void DYRegisterPlayerInstance(id p) {
    if (!p) return;
    BOOL added = NO;
    NSUInteger count = 0;
    os_unfair_lock_lock(&gLock);
    if (gPlayers && ![gPlayers containsObject:p]) {
        [gPlayers addObject:p];
        added = YES;
        count = gPlayers.count;
    }
    os_unfair_lock_unlock(&gLock);
    if (added) {
        NSLog(@"[DouYinKeepPlay][Recon] 注册 player 实例: %@ %p（共 %lu）",
              NSStringFromClass([p class]), p, (unsigned long)count);
    }
}

#pragma mark - v5 侦察：hook 通知注册，记录生命周期观察者

static DYImpAddObs orig_addObs;
static void hook_addObserver(id self, SEL _cmd, id observer, SEL sel, NSNotificationName name, id obj) {
    if ([name isEqual:UIApplicationWillResignActiveNotification] ||
        [name isEqual:UIApplicationDidEnterBackgroundNotification] ||
        [name isEqual:UIApplicationDidBecomeActiveNotification]) {
        NSString *desc = [NSString stringWithFormat:@"%@ -> %@",
                          NSStringFromClass([observer class]), NSStringFromSelector(sel)];
        BOOL fresh = NO;
        os_unfair_lock_lock(&gLock);
        if (![gReportedObservers containsObject:desc]) {
            [gReportedObservers addObject:desc];
            [gLifecycleObservers addObject:desc];
            fresh = YES;
        }
        os_unfair_lock_unlock(&gLock);
        if (fresh) NSLog(@"[DouYinKeepPlay][Recon] 生命周期观察者: %@", desc);
    }
    orig_addObs(self, _cmd, observer, sel, name, obj);
}

#pragma mark - 触摸判定：hook sendEvent:

static DYImpEvent orig_sendEvent;
static void hook_sendEvent(id self, SEL _cmd, UIEvent *event) {
    if (event && event.allTouches.count > 0) {
        os_unfair_lock_lock(&gLock);
        gLastTouchAt = [NSDate date];
        os_unfair_lock_unlock(&gLock);
    }
    orig_sendEvent(self, _cmd, event);
}

#pragma mark - 通知（公开 API）

static void DYRegisterNotifications(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        NSUInteger registered = 0;
        os_unfair_lock_lock(&gLock);
        gAppNonActive = YES;  // v7：拦截门置位（小窗/锁屏/后台统一入口）
        gResignAt = [NSDate date];  // v11：记录离前台时刻，供 VC.pause 拦截窗判定
        registered = gPlayers.count;
        os_unfair_lock_unlock(&gLock);
        NSLog(@"[DouYinKeepPlay][Diag] WillResignActive（注册 %lu 个 player）",
              (unsigned long)registered);
        DYEnterBackgroundKeepAlive();
    }];

    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        os_unfair_lock_lock(&gLock);
        gAppNonActive = YES;
        gResignAt = [NSDate date];  // v11：DidEnterBackground 也刷新（锁屏会进来）
        os_unfair_lock_unlock(&gLock);
        NSLog(@"[DouYinKeepPlay][Diag] DidEnterBackground");
        DYEnterBackgroundKeepAlive();
    }];

    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                     queue:[NSOperationQueue mainQueue]
                     usingBlock:^(NSNotification *note) {
        NSUInteger registered = 0;
        os_unfair_lock_lock(&gLock);
        gRecoverRunning = NO;
        gRecoverTicks = 0;   // ★ v16：必须清零 —— 否则下一轮切小窗时 tick
                             // 从上次的高位继续走，会立刻触到
                             // DY_RECOVER_MAX_TICKS，轮询刚起就收尾，
                             // 等于「第二次切小窗起不再停旧/不再恢复」
        gCandidates = nil;
        gLastTouchAt = nil;
        gAppNonActive = NO;
        gResignAt = nil;      // v11：回前台清离前台时刻，VC.pause 全放行
        gUserPausedAt = nil;  // v14：回前台清主动暂停标记（前台状态重新开始）
        gShouldRecover = NO;  // v9：回前台，恢复标志清空，交还控制权
        registered = gPlayers.count;
        os_unfair_lock_unlock(&gLock);
        DYEndBgTask();
        NSLog(@"[DouYinKeepPlay] 回前台，交还控制权（注册表仍保留 %lu）",
              (unsigned long)registered);
    }];
}

#pragma mark - v5 核心：枚举 Player 类并动态 hook

static void DYEnumerateAndHookPlayers(void) {
    if (!pMSHookMessageEx) return;

    // 找 IESVideoPlayerProtocol 协议对象（如果运行时可见）
    Protocol *iesProto = objc_getProtocol("IESVideoPlayerProtocol");

    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) {
        NSLog(@"[DouYinKeepPlay][Recon] objc_getClassList 返回 %d", numClasses);
        return;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * (numClasses + 16));
    if (!classes) return;
    numClasses = objc_getClassList(classes, numClasses);
    NSLog(@"[DouYinKeepPlay][Recon] 枚举到 %d 个类", numClasses);

    NSInteger hooked = 0;
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        const char *cname = class_getName(cls);
        if (!cname) continue;
        NSString *clsName = @(cname);

        // v7 筛选（收窄，防误伤）：
        // 1) 类名以 Aweme 开头且含 Player（AWE 系，feed 播放主路径）
        //    或 2) 实现 IESVideoPlayerProtocol 协议（自研播放器协议，语义明确）
        // v6 及以前 = 所有含 "Player" 的类（148 个，含 BDX/BDP/DVE/Krypton 等
        // 无关播放器，其 pause/setRate: 语义不明，误拦即破坏状态机 → 闪退）
        BOOL nameMatch = [clsName hasPrefix:@"Aweme"] &&
                         [clsName containsString:@"Player"] &&
                         ![clsName containsString:@"Layer"] &&
                         ![clsName containsString:@"Item"] &&
                         ![clsName containsString:@"View"] &&
                         ![clsName containsString:@"Controller"] &&
                         ![clsName containsString:@"Delegate"] &&
                         ![clsName containsString:@"Protocol"];
        BOOL protoMatch = iesProto && class_conformsToProtocol(cls, iesProto);
        if (!nameMatch && !protoMatch) continue;

        // 只 hook 有 pause 实例方法的类
        SEL pauseSel = @selector(pause);
        BOOL didHook = NO;

        // v15：三个 hook 全部改为 per-class block 捕获 orig（根治父子类交叉递归）
        // + 方法签名校验（底层 pause/play 是 void 无参 "v16@0:8"，setRate: 是 "v20@0:8f16"）
        // + 只 hook 类自己声明的实现（DYClassDeclaresSelector 查自身方法表）
        Method mPause = class_getInstanceMethod(cls, pauseSel);
        if (mPause && class_respondsToSelector(cls, pauseSel)
            && DYClassDeclaresSelector(cls, pauseSel)) {
            const char *enc = method_getTypeEncoding(mPause);
            if (enc && enc[0] == 'v') {
                __block DYImpVoid capturedOrig = NULL;
                IMP newImp = imp_implementationWithBlock(^(id s, SEL c) {
                    DYPlayerPauseImpl(s, c, capturedOrig);
                });
                if (newImp) {
                    void *origP = NULL;
                    pMSHookMessageEx(cls, pauseSel, (void *)newImp, &origP);
                    if (origP) {
                        capturedOrig = (DYImpVoid)origP;
                        gOrigPauseMap[clsName] = [NSValue valueWithPointer:origP];
                        didHook = YES;
                    }
                }
            }
        }

        SEL setRateSel = @selector(setRate:);
        Method mRate = class_getInstanceMethod(cls, setRateSel);
        if (mRate && class_respondsToSelector(cls, setRateSel)
            && DYClassDeclaresSelector(cls, setRateSel)) {
            const char *enc = method_getTypeEncoding(mRate);
            if (enc && enc[0] == 'v') {
                __block DYImpFloat capturedRate = NULL;
                IMP newImp = imp_implementationWithBlock(^(id s, SEL c, float r) {
                    DYPlayerSetRateImpl(s, c, r, capturedRate);
                });
                if (newImp) {
                    void *origRate = NULL;
                    pMSHookMessageEx(cls, setRateSel, (void *)newImp, &origRate);
                    if (origRate) {
                        capturedRate = (DYImpFloat)origRate;
                        gOrigSetRateMap[clsName] = [NSValue valueWithPointer:origRate];
                        didHook = YES;
                    }
                }
            }
        }

        // v8：play 只记录播放动作时间戳 + 放行（不拦截）
        SEL playSel = @selector(play);
        Method mPlay = class_getInstanceMethod(cls, playSel);
        if (mPlay && class_respondsToSelector(cls, playSel)
            && DYClassDeclaresSelector(cls, playSel)) {
            const char *enc = method_getTypeEncoding(mPlay);
            if (enc && enc[0] == 'v') {
                __block DYImpVoid capturedPlay = NULL;
                IMP newImp = imp_implementationWithBlock(^(id s, SEL c) {
                    DYPlayerPlayImpl(s, c, capturedPlay);
                });
                if (newImp) {
                    void *origPlay = NULL;
                    pMSHookMessageEx(cls, playSel, (void *)newImp, &origPlay);
                    if (origPlay) {
                        capturedPlay = (DYImpVoid)origPlay;
                        gOrigPlayMap[clsName] = [NSValue valueWithPointer:origPlay];
                        didHook = YES;
                    }
                }
            }
        }
        if (didHook) {
            [gHookedClasses addObject:clsName];
            hooked++;
            NSLog(@"[DouYinKeepPlay][Recon] hook 播放器类: %@（pause=%d setRate=%d play=%d）",
                  clsName,
                  class_respondsToSelector(cls, pauseSel),
                  class_respondsToSelector(cls, setRateSel),
                  class_respondsToSelector(cls, playSel));
        }
    }
    free(classes);
    gHooksInstalled = (hooked > 0);
    // 安装完成 → map 转 immutable，之后 pause/setRate:/play 热路径零锁读
    gOrigPauseMap = [gOrigPauseMap copy];
    gOrigSetRateMap = [gOrigSetRateMap copy];
    gOrigPlayMap = [gOrigPlayMap copy];
    NSLog(@"[DouYinKeepPlay][Recon] 共 hook %ld 个播放器类", (long)hooked);
}

#pragma mark - 入口

__attribute__((constructor)) static void DYCtor(void) {
    gBgTask = UIBackgroundTaskInvalid;
    gPlayers = [NSHashTable weakObjectsHashTable];
    gPlayerLastActive = [NSMapTable weakToStrongObjectsMapTable];  // v8：weak key 防播放器泄漏
    gOrigPauseMap = [NSMutableDictionary dictionary];
    gOrigSetRateMap = [NSMutableDictionary dictionary];
    gOrigPlayMap = [NSMutableDictionary dictionary];
    gHookedClasses = [NSMutableArray array];
    gLifecycleObservers = [NSMutableArray array];
    gReportedObservers = [NSMutableSet set];
    gBgStateClasses = [NSMutableArray array];
    gVCPauseMap = [NSMutableDictionary dictionary];
    gResignAt = nil;
    gUserPausedAt = nil;  // v14

    DYRegisterNotifications();
    DYResolveSubstrate();

    if (!pMSHookMessageEx) {
        NSLog(@"[DouYinKeepPlay] substrate 不可用，仅靠轮询恢复");
        return;
    }

    // 1. 枚举并 hook 所有 Player 类
    DYEnumerateAndHookPlayers();

    // 1b. v13：枚举业务 VC 并 hook 其 pause（根因修复：拦截切小窗自动暂停）
    DYHookBackgroundStateMachine();

    // 2. 触摸判定 + hook 探针
    Class UIApp = objc_getClass("UIApplication");
    if (UIApp) {
        pMSHookMessageEx(UIApp, @selector(sendEvent:), (void *)hook_sendEvent, (void **)&orig_sendEvent);
    }

    // 3. 侦察：记录生命周期通知观察者
    Class NC = objc_getClass("NSNotificationCenter");
    if (NC) {
        pMSHookMessageEx(NC, @selector(addObserver:selector:name:object:),
                         (void *)hook_addObserver, (void **)&orig_addObs);
    }

    NSLog(@"[DouYinKeepPlay] v15 初始化完成（底层播放器 %lu + 业务VC %lu，per-class orig/递归防护/签名校验）",
          (unsigned long)gHookedClasses.count, (unsigned long)gBgStateClasses.count);
#if DYDIAG
    DYScheduleReportAlert();
#endif
}
