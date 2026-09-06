#!/usr/bin/env bash
# setup.sh — 把 cc-base 框架资产注入式安装到 target 项目（Mac/Linux）。
# 用法：./setup.sh [--dry-run] [target_dir]    不给 target 默认当前目录 "."
# 流程：逐段校验 target 路径 → 上独占锁 + 落维护标记 → 复制 .claude 框架文件（跳过运行时产物）→
#   settings.json 合并（有 jq 自动 merge；无 jq 降级：新 target 直接复制，已有
#   settings 备份 .bak + 打印手工合并指引，不静默覆盖）→ 备份 .bak → 清标记与锁。
# --dry-run：一个字节都不写，只把 create / update / conflict / skip 四类计划打到 stdout。
set -u

die() {
  printf 'setup: %s\n' "$1" >&2
  exit 1
}

# 拼错的选项曾经是最贵的一种「成功」：`--dryrun` 不在选项表里，就被当成 target 收下，
# 于是一次本该只算不写的演练把 240 个文件真装进了 /tmp/x。以 - 开头的东西一律不许当路径，
# 报清楚合法选项、退 2（和 die 的 1 分开，让调用方分得出「参数用错」和「装到一半失败」）。
usage_die() {
  printf 'setup: %s\n' "$1" >&2
  printf '用法：setup.sh [-win|-mac|-ubt] [--dry-run] [--with-tests] [target_dir]\n' >&2
  printf '合法选项：-win  -mac  -ubt  --dry-run  --with-tests\n' >&2
  exit 2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

# --- target 路径逐段校验 ---
# 只挡 `..` 是不够的：一条路径里还有一堆段能把安装砸出打不开的目录——控制字符、Windows 三类
# 禁忌（非法字符 <>:"|?* / 保留设备名 / 段尾的点与空格）、超长段、深到离谱的嵌套。这些在 Linux
# 上建得出来，同一棵树搬到 Windows 就废了，装完才发现比装不上贵。
# 必须跑在任何 mkdir 之前——「拒绝了但目录已经建了一半」不叫拒绝。
WIN_BAD_CHARS='<>:"|?*'
WIN_RESERVED='con prn aux nul com1 com2 com3 com4 com5 com6 com7 com8 com9 lpt1 lpt2 lpt3 lpt4 lpt5 lpt6 lpt7 lpt8 lpt9'
MAX_SEG_BYTES=255
MAX_SEGS=64
validate_target() {
  local target=$1 rest oldifs seg lower ch i n count first
  [ -n "$target" ] || die "target 目录不能是空串"
  # 前导 ./ 和单独的 . 是文档写死的默认形态（不给参数就是 "."），先摘掉再逐段查；
  # 照字面拒绝所有 . 段的话，最常用的两种写法当场被砖掉。
  rest=$target
  case "$rest" in
    .) return 0 ;;
    ./*) rest=${rest#./} ;;
  esac
  # 按 / 切段后立刻把 IFS 和 glob 还原，后面的检查在干净环境里跑。set -f 是必需的：
  # 段里可能有 * ?，不关 glob 的话切分那一下会拿它们去匹配当前目录。
  oldifs=$IFS
  set -f
  IFS='/'
  # shellcheck disable=SC2086  # 这里就是要 word splitting
  set -- $rest
  IFS=$oldifs
  set +f
  count=0
  for seg in "$@"; do
    [ -n "$seg" ] && count=$((count + 1))
  done
  [ "$count" -le "$MAX_SEGS" ] \
    || die "target 路径段数过多：$count 段，上限 $MAX_SEGS 段（嵌套这么深多半是路径拼错了）：$target"
  first=1
  for seg in "$@"; do
    [ -n "$seg" ] || continue
    # Windows 盘符（C: 这一段）只在开头合法，放行后面的按普通段查
    if [ "$first" = "1" ]; then
      first=0
      case "$seg" in [A-Za-z]:) continue ;; esac
    fi
    case "$seg" in
      ..) die "target 路径不安全：段 '..' 会把文件写到目标之外（$target）" ;;
      .) die "target 路径不合法：路径中间出现 '.' 段（$target）；相对路径只允许开头的 ./" ;;
    esac
    if [ -n "$(printf '%s' "$seg" | LC_ALL=C tr -dc '\001-\037\177')" ]; then
      die "target 路径段含控制字符（control char）：段 [$seg]（$target）"
    fi
    i=0
    n=${#WIN_BAD_CHARS}
    while [ "$i" -lt "$n" ]; do
      ch=${WIN_BAD_CHARS:$i:1}
      case "$seg" in
        *"$ch"*) die "target 路径段含非法字符 [$ch]（Windows 文件名不许带 $WIN_BAD_CHARS）：段 [$seg]（$target）" ;;
      esac
      i=$((i + 1))
    done
    lower=$(printf '%s' "$seg" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case " $WIN_RESERVED " in
      *" $lower "*) die "target 路径段是 Windows 保留设备名 [$seg]（con/prn/aux/nul/com1-9/lpt1-9，不分大小写）：$target" ;;
    esac
    case "$seg" in
      *.) die "target 路径段以点结尾（trailing dot，Windows 会把它悄悄吃掉）：段 [$seg]（$target）" ;;
      *' ') die "target 路径段以空格结尾（trailing space，同上）：段 [$seg]（$target）" ;;
    esac
    if [ "$(printf '%s' "$seg" | wc -c | tr -d ' ')" -gt "$MAX_SEG_BYTES" ]; then
      die "target 路径单段超长：超过 $MAX_SEG_BYTES 字节（多数文件系统的单段上限）：段 [$seg]（$target）"
    fi
  done
}

# --- 安装事务：dry-run 计划 / 独占锁 / 维护标记 ---
# 锁：同一个目标被两个 setup 同时写，装出来的树谁也说不清。锁里记 pid——pid 还活着就拒绝，
#   pid 已死是上次崩溃的残留（陈旧锁），接管并在 stderr 说一句，不让自己的残留把目标锁死。
# 标记：安装期间 status=active，正常收尾删掉；中途挂了由 EXIT trap 翻成 interrupted 并附已写
#   文件清单（重装要知道上次写到哪）。doctor.sh 和 SessionStart 横幅都看这个文件。
# 两者都住在 .claude/.runtime/（排除表已挡，不入装），装完连空目录一起清掉。
DRY_RUN=0
WITH_TESTS=0
TARGET_ROOT=""
RUNTIME_DIR=""
LOCK_FILE=""
MARKER_FILE=""
INSTALL_DONE=0
WRITE_COUNT=0
WRITTEN_LIST=""
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
PLAN_CREATE=0
PLAN_UPDATE=0
PLAN_CONFLICT=0
PLAN_SKIP=0

plan_note() {
  case "$1" in
    create) PLAN_CREATE=$((PLAN_CREATE + 1)) ;;
    update) PLAN_UPDATE=$((PLAN_UPDATE + 1)) ;;
    conflict) PLAN_CONFLICT=$((PLAN_CONFLICT + 1)) ;;
    skip) PLAN_SKIP=$((PLAN_SKIP + 1)) ;;
  esac
  # 计划打 stdout：stderr 是给人看的告警，计划是给人核对的产物
  [ "$DRY_RUN" = "1" ] && printf '  %-8s %s\n' "$1" "$2"
  return 0
}

# 目标已有该文件时按内容分 update/skip，没有就是 create（settings.json 走 merge、MANIFEST、
# feedback INDEX 这三个不归 copy_claude_tree 管，dry-run 里不能凭空少报）。
plan_pair() {
  if [ ! -e "$2" ]; then
    plan_note create "$3"
  elif cmp -s "$1" "$2"; then
    plan_note skip "$3"
  else
    plan_note update "$3"
  fi
}

# 每写一个文件记一笔（中断留痕用）。CC_SETUP_FAIL_AFTER=N 是测试用的故障注入口：第 N 次写入后
# 强制失败，用来验中断留痕；没设这个变量时整段不生效。
note_write() {
  WRITE_COUNT=$((WRITE_COUNT + 1))
  WRITTEN_LIST="${WRITTEN_LIST}${1#"$TARGET_ROOT"/}
"
  case "${CC_SETUP_FAIL_AFTER:-}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$WRITE_COUNT" -lt "$CC_SETUP_FAIL_AFTER" ] \
    || die "CC_SETUP_FAIL_AFTER=$CC_SETUP_FAIL_AFTER 故障注入生效：写完第 $WRITE_COUNT 个文件后强制中止"
}

write_marker() {
  local files
  [ -n "$MARKER_FILE" ] || return 0
  files=$(printf '%s' "$WRITTEN_LIST" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/",/' | tr -d '\n')
  printf '{"status": "%s", "pid": %s, "startedAt": "%s", "written": [%s]}\n' \
    "$1" "$$" "$STARTED_AT" "${files%,}" >"$MARKER_FILE" 2>/dev/null || true
}

# die / 故障注入 / 意外退出都会走到这里：标记翻 interrupted 留在原地，锁一律释放（持锁的是本
# 进程，本进程都要没了）。不调 exit，免得把原来的退出码顶掉。
on_exit() {
  [ -n "$MARKER_FILE" ] || return 0
  [ "$INSTALL_DONE" = "1" ] || write_marker interrupted
  [ -z "$LOCK_FILE" ] || rm -f "$LOCK_FILE"
}
trap on_exit EXIT

# 锁的创建必须是原子的：旧写法「先 [ -f ] 判存在、再 printf > 写入」是两步，两个 setup
# 同时起就能双双通过存在性判断、各写一次锁，双双以为自己持锁往下装（实测约 8% 命中）。
# 改用 set -o noclobber：开着它时 `>` 对已存在的文件直接失败（底下是 O_CREAT|O_EXCL），
# 判存在与写入合成一次系统调用，抢不到的那个当场就知道自己没拿到。
# 选 noclobber 而不是 mkdir 目录形态：锁还是同一个路径上的一个普通文件——陈旧锁读 pid、
# 装完 rm -f、doctor 与 tests 里那些按文件形态判的地方全都不用跟着改，改动面只落在这个函数里。
acquire_lock() {
  local lock="$RUNTIME_DIR/install.lock" pid try=0
  mkdir -p "$RUNTIME_DIR" || die "无法创建运行态目录：$RUNTIME_DIR"
  while :; do
    try=$((try + 1))
    # noclobber 只开在子 shell 里：不把这个选项漏给后面的复制流程（那边 > 覆盖是正常操作）。
    if (set -o noclobber; printf '{"pid": %s, "startedAt": "%s"}\n' "$$" "$STARTED_AT" >"$lock") 2>/dev/null; then
      LOCK_FILE=$lock
      return 0
    fi
    # 没抢到有两种可能：锁已经在那儿（正常竞争），或者压根写不进去（权限 / 磁盘满）。
    # 后者路径上不会有锁，别把写不进去误报成「别人持锁」。
    [ -e "$lock" ] || die "无法写入锁文件：$lock"
    pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$lock" 2>/dev/null | head -1)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "另一个 setup 正在写这个目标：锁 $lock 的持有者 pid=$pid 还活着；等它跑完，或确认那个进程已经没了再删锁重试"
    fi
    printf 'setup: 陈旧锁（stale）%s：持有者 pid=%s 已不存在，接管；上一次安装多半是崩在半路的。\n' \
      "$lock" "${pid:-未知}" >&2
    # 接管陈旧锁是「删掉重抢」而不是「直接覆盖」：覆盖就又变回两步。删完到重抢之间锁被
    # 别人先建走时，下一圈会重新读 pid 判活，不会误以为自己持锁。
    rm -f "$lock" || die "无法清除陈旧锁：$lock"
    # 重抢有上限：清了又被抢走、连着几回都拿不到，说明旁边有人持续抢占，
    # 报错退出好过在这儿无界空转。
    [ "$try" -lt 3 ] || die "反复抢不到安装锁：$lock 已清除陈旧锁 $try 次仍被抢占；确认没有别的 setup 在跑再重试"
  done
}

start_marker() {
  MARKER_FILE="$RUNTIME_DIR/install.marker"
  write_marker active
  [ -f "$MARKER_FILE" ] || die "无法写入维护标记：$MARKER_FILE"
}

# 正常收尾：标记和锁都删掉，连空的 .runtime 一起清（tests/test-setup.sh ⑤ 按 -e 判目录，
# 留个空壳会让「运行态目录不入装」那条当场红）。目录里还有别的运行态文件时 rmdir 自然失败，不强删。
finish_install() {
  INSTALL_DONE=1
  [ -z "$MARKER_FILE" ] || rm -f "$MARKER_FILE"
  MARKER_FILE=""
  [ -z "$LOCK_FILE" ] || rm -f "$LOCK_FILE"
  LOCK_FILE=""
  [ -z "$RUNTIME_DIR" ] || rmdir "$RUNTIME_DIR" 2>/dev/null || true
}

copy_file() {
  local src=$1 dest=$2 mode=${3:-}
  mkdir -p "$(dirname "$dest")" || die "无法创建目录：$(dirname "$dest")"
  if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
    cp -p "$dest" "$dest.bak" || die "无法备份 $dest"
    printf 'backup: %s.bak\n' "$dest"
  fi
  cp -p "$src" "$dest" || die "无法复制 $src → $dest"
  [ -n "$mode" ] && chmod "$mode" "$dest"
  note_write "$dest"
}

# --- 框架核心层 vs 项目私有层（FRAMEWORK-MANIFEST.txt）---
# 目标侧旧 MANIFEST 记录了上次安装时各框架文件的 SHA（LF 归一化后 sha256，抗 autocrlf）。
# 覆盖前对照：目标文件 == 旧框架版本 → 安全覆盖升级；用户改过或无旧 MANIFEST → 不覆盖，
# 落 <name>.framework-new 供手工合并。不在清单里的目标侧文件 = 私有层，一律不动。
norm_sha() { tr -d '\r' <"$1" | sha256sum | awk '{print $1}'; }

OLD_MANIFEST=""          # 目标侧旧 MANIFEST 路径（存在时）
FRAMEWORK_NEW_LIST=""    # 本次落 .framework-new 的文件列表（换行分隔）

manifest_sha_of() {
  # $1=rel 路径；从旧 MANIFEST 查该文件上次安装时的 SHA，查不到输出空
  [ -n "$OLD_MANIFEST" ] || return 0
  awk -F '\t' -v p="$1" '$0 !~ /^#/ && $1 == p { print $2; exit }' "$OLD_MANIFEST"
}

# 复制 .claude 框架树，跳过运行时产物 / 待删 / 机器特定文件；settings.json 不在此复制（走 merge）。
# 下面的排除表另有三份，改这里必须同改：.claude/scripts/gen-manifest.sh 的 case（清单侧同一套口径，
#   分叉了就会出现「装了但不在清单」或「在清单但没装」）、setup.ps1 的 $skip + 目录正则（Windows 安装侧）、
#   .claude/harness/lib/release.mjs MANIFEST_RULES。
# 不共用一份来源是有意的：setup.sh 要能被单独取走对着源码树跑，多一个 source 依赖就多一条装不上的路。
# 四份手工同步的口径由测试兜：.claude/tests/test-setup.sh 的 ⑥ 逐臂比对四份表，
#   .claude/tests/test-release-manifest.sh 造真文件锁生成器与审计者两侧行为一致。
copy_claude_tree() {
  local src_dir=$1 dest_dir=$2 rel src dest old_sha
  [ -d "$src_dir" ] || die "源 .claude 不存在：$src_dir"
  [ -f "$dest_dir/FRAMEWORK-MANIFEST.txt" ] && OLD_MANIFEST="$dest_dir/FRAMEWORK-MANIFEST.txt"
  while IFS= read -r -d '' src; do
    rel=${src#"$src_dir"/}
    case "$rel" in
      FRAMEWORK-MANIFEST.txt) continue ;;                          # 清单最后单独覆盖安装
      settings.json) continue ;;                                   # 走 merge_settings，不直接覆盖
      settings-windows.json) continue ;;                           # 无效产物（Claude Code 不加载），不传播
      settings.local.json) continue ;;                             # 机器特定覆盖，不入装
      .needs-review|.needs-review.lock) continue ;;                # stop-gate 运行时状态
      .tdd-exempt|.red-verified|.static-gate|.degraded-review) continue ;;  # 闸门运行时标记
      .fast-mode|.subagent-reminded) continue ;;                   # 运行态标记
      .stop-gate-strikes|.precompact-block-epoch|.async-verify-last) continue ;;  # 闸门计数 / 纪元 / 异步校验游标
      signals.jsonl|*/signals.jsonl) continue ;;                   # evolution 运行态信号队列（任意层级 basename）
      evidence/*) continue ;;                                      # 运行态证据目录
      harness/receipts/*) continue ;;                              # 大仓治理运行态回执（harness.mjs / catalog 本体照常复制分发）
      harness/state/*) continue ;;                                 # 证据哈希链 + 活跃 task 信封 + 评审会话（源机专属，装到别人项目里就是脏数据）
      harness/waivers/*) continue ;;                               # 结构化 per-check 豁免
      harness/trend/*) continue ;;                                 # 架构漂移趋势台账（arch-check --record 快照）
      harness/evidence/*) continue ;;                              # 每条 check 的原始 stdout/stderr
      .runtime/*) continue ;;                                      # supervisor 进程守护运行态（supervisor.mjs 本体照常复制分发）
      worktrees/*) continue ;;                                     # Claude Code sub-agent 的 worktree 隔离副本（整棵仓副本，装进别人项目就是别人的仓）
      tests/*) continue ;;                                         # 框架自测：默认不装，--with-tests 在循环外整目录拷（另三份表同此臂）
      research/*) continue ;;                                      # 设计底本：不分发
      agent-memory/*) continue ;;                                  # 本仓 sub-agent 记忆：不分发
      *.bak|*.framework-new) continue ;;                           # 安装器自己的产物：开发机上留下的残留不该被装进别人项目（另三份排除表同此臂）
      .DS_Store|*/.DS_Store) continue ;;                           # macOS 目录元数据（每层都会长，.claude/.gitignore 同条）
      Thumbs.db|*/Thumbs.db) continue ;;                           # Windows 缩略图缓存（.claude/.gitignore 同条）
      *.swp) continue ;;                                           # vim 交换文件（.claude/.gitignore 同条）
      feedback/templates/*) ;;                                     # 保留模板（顶层 *.md 才是私人经验）
      feedback/*/*) ;;                                              # 保留 feedback 子目录其他文件
      feedback/*.md) continue ;;                                    # 私人进化经验（顶层 *.md）；INDEX 装后重置为模板
    esac
    dest="$dest_dir/$rel"
    # manifest 分层判断：目标已存在且内容不同时才需要区分「可升级」vs「用户改过」
    if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
      old_sha=$(manifest_sha_of "$rel")
      if [ -n "$old_sha" ] && [ "$(norm_sha "$dest")" = "$old_sha" ]; then
        plan_note update ".claude/$rel"  # 目标 == 旧框架版本，安全覆盖升级（copy_file 仍留 .bak）
      else
        # 用户改过（SHA 与旧 MANIFEST 不符）或目标无 MANIFEST（老版本装的）→ 不覆盖
        plan_note conflict ".claude/$rel"
        [ "$DRY_RUN" = "1" ] && continue
        cp -p "$src" "$dest.framework-new" || die "无法写入 $dest.framework-new"
        FRAMEWORK_NEW_LIST="${FRAMEWORK_NEW_LIST}${rel}
"
        note_write "$dest.framework-new"
        continue
      fi
    elif [ -e "$dest" ]; then
      plan_note skip ".claude/$rel"
    else
      plan_note create ".claude/$rel"
    fi
    [ "$DRY_RUN" = "1" ] && continue
    copy_file "$src" "$dest"
  done < <(find "$src_dir" -type f -print0)
  # --with-tests：框架自测整目录照拷（不走 manifest 分层——它们是框架的测试不是用户文件，升级时直接换新）
  if [ "$WITH_TESTS" = "1" ] && [ -d "$src_dir/tests" ]; then
    while IFS= read -r -d '' src; do
      rel=${src#"$src_dir"/}
      case "$rel" in tests/golden/*|tests/fixtures/*|tests/*) ;; *) continue ;; esac
      plan_note create ".claude/$rel"
      [ "$DRY_RUN" = "1" ] && continue
      copy_file "$src" "$dest_dir/$rel"
    done < <(find "$src_dir/tests" -type f -print0)
  fi
}

merge_settings() {
  local src=$1 dest=$2 tmp
  mkdir -p "$(dirname "$dest")" || die "无法创建 settings 目录"
  if [ ! -f "$dest" ]; then
    copy_file "$src" "$dest"
    return
  fi
  # 无 jq 降级：target 已有 settings.json 时不静默覆盖——备份 .bak 后保留原文件，打印手工合并指引，
  # 其余资产照常已复制完（不中断安装）。有 jq 仍走下面的自动合并。
  if ! command -v jq >/dev/null 2>&1; then
    cp -p "$dest" "$dest.bak" || die "无法备份 $dest"
    printf 'backup: %s.bak\n' "$dest"
    printf 'setup: 本机无 jq，settings.json 未自动合并（保留你原有的 %s）。\n' "$dest" >&2
    printf 'setup: 请手工把框架 settings.json 里的 hooks 合并进去（来源：%s），\n' "$src" >&2
    printf 'setup: 要点：把 source 各 event 下的 hook command 追加到 target 同名 event，已有的不重复加。\n' >&2
    return
  fi
  # target 已有 settings.json：先清掉老版本装的 shell 形态 hook command（.sh / .ps1 都算），再追加
  # target 尚无的 exec form command，不动用户其他配置。老安装升级上来后旧形态不再残留报错。
  # 判定「历史残留」只认框架形态：command 或 args 任一项指向 .claude/hooks/<name>.sh|.ps1——
  # 只认这条路径，不误伤用户自定义 command。
  # 去重键是 command + args 整体：exec form 下每条 hook 的 command 都是字面 node，只比 command 会把
  # 21 条全判成「已存在」，一条都合不进去。
  tmp=$(mktemp) || die "无法创建临时文件"
  jq -s '
    def is_legacy_hook:
      ([(.command // "")] + ((.args // []) | map(tostring)))
      | any(test("\\.claude[/\\\\]hooks[/\\\\][A-Za-z0-9_-]+\\.(sh|ps1)"));
    def clean_legacy:
      if .hooks then
        .hooks |= with_entries(.value |= map(.hooks |= map(select(is_legacy_hook | not))))
      else . end;
    def hook_id: (.command // "") + " " + (((.args // []) | map(tostring)) | join(" "));
    def commands: [.. | objects | select((.command? // "") != "") | hook_id] | unique;
    .[0] as $tgt0
    | .[1] as $source
    | ($tgt0 | clean_legacy) as $target
    | ($target | commands) as $existing
    | reduce (($source.hooks // {}) | keys_unsorted[]) as $event ($target;
        reduce (($source.hooks[$event] // [])[]) as $group (.;
          ($group.hooks // []
            | map(select(hook_id as $id | ((.command // "") != "" and (($existing | index($id)) | not)))))
          as $new_hooks
          | if ($new_hooks | length) > 0 then
              .hooks[$event] = ((.hooks[$event] // []) + [($group | .hooks = $new_hooks)])
            else
              .
            end
        )
      )
    | if (has("statusLine") | not) and ($source | has("statusLine")) then .statusLine = $source.statusLine else . end
  ' "$dest" "$src" >"$tmp" || { rm -f "$tmp"; die "无法合并 settings.json"; }
  mv "$tmp" "$dest" || { rm -f "$tmp"; die "无法更新 settings.json"; }
  note_write "$dest"
}

main() {
  # 平台参数 -win/-mac/-ubt（默认按 uname 检测）。win → 调 setup.ps1；mac/ubt → 本脚本直接装。
  local platform=""
  local target="."
  while [ $# -gt 0 ]; do
    case "$1" in
      -win) platform="win" ;;
      -mac) platform="mac" ;;
      -ubt) platform="ubt" ;;
      --dry-run) DRY_RUN=1 ;;
      --with-tests) WITH_TESTS=1 ;;
      -*) usage_die "未知选项：$1" ;;
      *) target="$1" ;;
    esac
    shift
  done
  [ -z "$platform" ] && case "$(uname -s)" in
    Darwin) platform="mac" ;;
    Linux) platform="ubt" ;;
    MINGW*|MSYS*|CYGWIN*) platform="win" ;;
    *) platform="ubt" ;;
  esac
  if [ "$platform" = "win" ]; then
    local sd ps
    sd=$(cd "$(dirname "$0")" && pwd) || die "无法定位脚本目录"
    if command -v pwsh >/dev/null 2>&1; then
      ps=pwsh
    elif command -v powershell.exe >/dev/null 2>&1; then
      ps=powershell.exe
    else
      die "Windows 平台需 pwsh 或 powershell.exe；请在 Windows 跑 setup.sh -win，或本机装 pwsh"
    fi
    # --dry-run 转交时要跟着过去，否则 Windows 侧会真装（开关名不同：ps1 侧是 -DryRun）
    if [ "$DRY_RUN" = "1" ]; then
      exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$sd/setup.ps1" -Target "$target" -DryRun
    fi
    exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$sd/setup.ps1" -Target "$target"
  fi
  # jq 可选：有则 settings.json 自动合并；无则降级（新 target 直接复制，已有 settings 备份 .bak + 手工合并指引）
  command -v jq >/dev/null 2>&1 || printf 'setup: 未检测到 jq，settings.json 走无 jq 降级路径。\n' >&2

  validate_target "$target"

  local script_dir source_dir hooks_count skills_count
  script_dir=$(cd "$(dirname "$0")" && pwd) || die "无法定位脚本目录"
  source_dir=$script_dir
  [ -d "$source_dir/.claude" ] || die "脚本目录下无 .claude（请在 cc-base 仓库根运行）"
  TARGET_ROOT=$target
  RUNTIME_DIR="$target/.claude/.runtime"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'dry-run: 只算不写，%s 一个字节都不动\n' "$target"
  else
    mkdir -p "$target" || die "无法创建 target：$target"
    [ -w "$target" ] || die "target 不可写：$target"
    acquire_lock
    start_marker
  fi

  copy_claude_tree "$source_dir/.claude" "$target/.claude"

  # dry-run 到此为止：把 copy_claude_tree 没管的三个文件补进计划，打计数，退出
  if [ "$DRY_RUN" = "1" ]; then
    plan_pair "$source_dir/.claude/settings.json" "$target/.claude/settings.json" ".claude/settings.json"
    if [ -f "$source_dir/.claude/FRAMEWORK-MANIFEST.txt" ]; then
      plan_pair "$source_dir/.claude/FRAMEWORK-MANIFEST.txt" "$target/.claude/FRAMEWORK-MANIFEST.txt" \
        ".claude/FRAMEWORK-MANIFEST.txt"
    fi
    if [ -f "$source_dir/.claude/feedback/templates/feedback-index-template.md" ]; then
      plan_pair "$source_dir/.claude/feedback/templates/feedback-index-template.md" \
        "$target/.claude/feedback/FEEDBACK-INDEX.md" ".claude/feedback/FEEDBACK-INDEX.md"
    fi
    printf 'dry-run: create=%s update=%s conflict=%s skip=%s（conflict 真装时会落 <文件>.framework-new）\n' \
      "$PLAN_CREATE" "$PLAN_UPDATE" "$PLAN_CONFLICT" "$PLAN_SKIP"
    return 0
  fi

  merge_settings "$source_dir/.claude/settings.json" "$target/.claude/settings.json"

  # 装完把新 MANIFEST 复制进目标（下次升级据此区分「框架旧版可覆盖」vs「用户改过不可覆盖」）
  if [ -f "$source_dir/.claude/FRAMEWORK-MANIFEST.txt" ]; then
    copy_file "$source_dir/.claude/FRAMEWORK-MANIFEST.txt" "$target/.claude/FRAMEWORK-MANIFEST.txt"
  fi

  # 汇总本次未覆盖的用户改动文件（新版本已放 .framework-new 供手工合并）
  if [ -n "$FRAMEWORK_NEW_LIST" ]; then
    local fn_count
    fn_count=$(printf '%s' "$FRAMEWORK_NEW_LIST" | grep -c .)
    printf 'setup: %s 个文件用户侧有改动，未覆盖；新版本已放 <文件>.framework-new 供手工合并：\n' "$fn_count" >&2
    printf '%s' "$FRAMEWORK_NEW_LIST" | sed 's/^/setup:   - .claude\//' >&2
  fi

  # feedback 顶层经验已在 copy_claude_tree 跳过；把 INDEX 重置为干净模板（与 make-release.sh 同源）
  local fb_tpl="$source_dir/.claude/feedback/templates/feedback-index-template.md"
  [ -f "$fb_tpl" ] && copy_file "$fb_tpl" "$target/.claude/feedback/FEEDBACK-INDEX.md"

  hooks_count=$(find "$source_dir/.claude/hooks" -maxdepth 1 -type f -name '*.mjs' 2>/dev/null | wc -l | tr -d ' ')
  skills_count=$(find "$source_dir/.claude/skills" -type f 2>/dev/null | wc -l | tr -d ' ')

  # 装完跑 fix-platform.sh 清老安装遗留的 .sh/.ps1 hook + 归一 statusLine（python3 兜底，无 jq 也清）
  if [ -f "$target/.claude/scripts/fix-platform.sh" ] && command -v python3 >/dev/null 2>&1; then
    printf 'setup: 跑 fix-platform.sh 清理历史 .sh/.ps1 残留 + 归一 statusLine...\n' >&2
    ( cd "$target" && CLAUDE_PROJECT_DIR="$target" bash "$target/.claude/scripts/fix-platform.sh" ) >&2 || true
  fi
  finish_install
  printf 'installed: hooks=%s skills=%s target=%s\n' "$hooks_count" "$skills_count" "$target"
  printf '完成。Claude Code 会从 %s/.claude/settings.json 加载 hooks（node 跑 .mjs，三平台同一份）。\n' "$target"
  printf '本机没有 bash（Windows 纯 PowerShell）时改用： pwsh -File setup.ps1 -Target %s\n' "$target"
}

main "$@"
