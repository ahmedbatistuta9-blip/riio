# PS3 static-recomp porting playbook (ps3recomp)

These are generic lessons from bringing up inFamous (BCES00220) on the ps3recomp toolkit. Use them for
the next title. Game-specific state lives in each port's `HANDOFF.md` (e.g. `infamous-recomp\HANDOFF.md`).

**Edition: THOROUGH (2026-10-04).** This edition keeps everything that could matter, including dead ends
and exact numbers. A condensed "straight to the point" edition will be written from it once inFamous is
done. Rule for edits: add, do not delete; mark superseded advice as superseded instead of removing it.

**Where things stand (inFamous, 2026-10-04 evening):** boots, loads the world, renders the title screen
("Press the Start Button") at ~4.5 fps on an RTX 4060 PC, accepts input, leaves the title screen and
starts loading the game. Most fixes live in the shared toolkit (`ps3recomp/`), so the next title gets
them for free.

## Contents
1. Working setup (session shape, Linux fast loop, sandbox traps, Windows compile check, the
   user-run protocol)
2. Runtime facts that bite every title (numbered list 1-33)
3. SPU / SPURS performance (interpreter fallbacks, SPURS throughput, parallel-kernel deadlock)
4. Diagnostic recipe: "it boots but the screen is black"
5. The D3D12 RSX backend: architecture and every lesson learned
6. Input (cellPad)
7. Performance work: how to measure, what the numbers mean, where inFamous stands
8. Index of environment variables and log tags
9. Per-title checklist
10. Second title: Tokyo Jungle -- what generalised (facts 34-76, bridge mechanics, FIFO parks, HLE audit)
11. inFamous v102: SPURS workload lifecycle (facts 77-80), CPU-side perf lessons, running two agents
12. inFamous v103: frame split / forced frame end / black detection, freeze diagnostics, lifted-code register caching,
    per-object lwcond waits, reviewing a multi-agent change set (facts 81-109)
13. inFamous v121-v124: the world freeze = untranslated vslo/vsl; finding a game's own freeze flag; inFamous engine
    map and an inFamous 2 checklist (facts 110-117)

---

## 1. Working setup that works

### 1.1 Shape of the session
* The user's PC (Windows) holds the disc dump, the `ps3recomp` checkout, and the per-game
  `<game>-recomp` port.
* Claude's cloud session reaches that folder through the device bridge:
  * `device_bash` is a **Linux VM**: 2 cores, ~3 GB RAM, ~250 MB free disk.
  * In that VM, the user's folder is mounted at `~/mnt/<folder>`.
  * The VM **cannot run the Windows exe**.
* The user does not want Claude driving their screen, so do not use computer use. Even if it
  were allowed, File Explorer is click-only and terminals are untypable.

### 1.2 The fast loop: build and run on Linux in the cloud container
1. **Get the code over.**
   * Tar the code (exclude `.git`, `*.log`, build dirs) into the connected folder.
   * `device_stage_files` it, then extract into `/home/claude/w`.
   * Do not exclude the pattern `build*`, or you lose `tools/build_spu_workloads.py`.
2. **Install dependencies.**
   * `apt` is blocked by the proxy. Build SDL2 from `github.com/libsdl-org/SDL`
     (release-2.30.x) with CMake/Ninja and install to `/usr/local`.
   * That is the only hard dependency.
3. **Build.**
   * Use `clang`/`clang++` with `-O1` (the SPU sources force `-O2` themselves).
   * 5 lifted TUs of ~40 MB each compile in about 10 minutes on 2 cores.
4. **Get the game data over.**
   * Do not copy the whole disc. Collect `[fs] open '...'` lines from a Windows log and stage only those.
   * Limits: 50 files / 500 MB per call, 400 MB per file. `split -b` bigger files on the device side and `cat` them back.
   * hdd0 "install" copies are usually byte-identical to bdvd. Hardlink them.
5. **Run headless.**
   * Use `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy`. The RSX null backend is selected automatically.
   * Always launch with `nohup timeout -s KILL <sec> ... & disown` and poll the logs.
     Foreground runs die at the tool timeout.
   * The container can restart: `/home/claude` persists, `/tmp` does not.
6. **Port fixes back.**
   * The user's sources are often **CRLF, or mixed**. Python text mode silently converts to LF.
   * Re-apply each edit onto the original bytes. Diff on CR-stripped lines and reuse the
     neighbouring line's ending, then `device_commit_files`.
   * Verify the old files' mtimes didn't change first.

### 1.3 Sandbox traps
* **Deletion is off by default** in the connected folder. Any tool that creates a temp file and
  then removes it leaves litter. `git status` leaves `.git/index.lock`, which blocks the user's git.
  * Don't run git there.
  * If a stale file gets created, `mv` it to `_to_delete\` (rename works where unlink doesn't) and tell the user.
* `pkill -f <name>` matches your own bash command line and kills the shell. Use `pkill -x`.
* `cmd 2>&1 >f | grep > g` block-buffers, so the log looks frozen. Write raw files.
* Logs can be hundreds of MB. Always `grep -c`, `tail -c`, or `cut -c1-200`; never cat them.
* **The cloud container can restart mid-session, and files written shortly before are truncated to 0 bytes**
  (seen: the freshly linked exe and `libps3recomp_runtime.a`). Run `sync` after every build. After a restart,
  `find build-linux -size 0` and delete those so ninja relinks them.
* Two game instances at once on the 2-core VM is enough to trigger that restart. Run one at a time.
* **Check Windows-only code from Linux:** `pip install ziglang`, then
  `python3 -m ziglang cc -target x86_64-windows-gnu -c -o x.o -I... file.c`. The mingw headers include
  d3d12.h, audioclient.h and xinput.h. Use `-c -o`; `-fsyntax-only` fails with "FileNotFound".

### 1.4 Compile-check Windows-only code (D3D12 backend) without the user's PC
* In Claude's cloud container: `pip install --break-system-packages ziglang` (zig ships MinGW-w64 headers,
  including d3d12.h, d3d12sdklayers.h, dxgi1_6.h, d3dcompiler.h, and DRED types).
* `python3 -m ziglang cc -target x86_64-windows-gnu -c -o /tmp/x.o -std=c11 -w -Werror=implicit-function-declaration
  -Werror=incompatible-pointer-types -I. -I.. -I../../include -I../../runtime -I../../runtime/ppu file.c`
  (from libs/video). `-fsyntax-only` misbehaves (FileNotFound); compile to an object instead.
* Do it before every hand-off to the user. A failed build costs a whole round trip.

### 1.5 The user-run protocol (Windows): one build, one run, read the log
* Claude cannot run the Windows exe. The user runs `build.cmd` (clang-cl + Ninja, `build-fast\`) and then the
  game (`play.cmd`/`run.cmd`/`run_dump*.cmd`); stdout goes to `play.out.log`, stderr to `play.err.log` in
  `infamous-recomp\`. Every round trip costs the user minutes, so:
  * Batch fixes: ship everything that is ready in one build, each behind an env var where risky.
  * Add the diagnostics for the NEXT question in the same build (e.g. `[SLOWFRAME]` was added together with
    a fix, and the next log answered "GPU or CPU, memory or compiles" without another round trip).
  * Always say exactly what to look for in the log and on screen.
* Before every push: zig compile-check (1.4); keep the file's line endings (CRLF in this tree; Python text mode
  converts to LF -- convert back with `sed 's/$/\r/'`); back up the device's current file to
  `_xfer\bak_<date><letter>\` (also copy the last run's logs there); `device_commit_files`; verify with `md5sum`
  on the device. The `_xfer\bak_*` folders are the rollback path.
* Logs are overwritten by the next run. Copy `play.err.log`/`play.out.log` into the backup folder before
  pushing, so the evidence for each change survives.
* Screenshots are the fastest signal: the window title shows `FPS`, `draws` and resolution, which already
  diagnosed one bug (`draws: 2048` = the record cap).

---

## 2. Runtime facts that bite every title (numbered list; numbers are stable references)

1. **Know which code paths are Windows-only.** Before trusting a Linux run, grep for
   `#ifdef _WIN32` around anything synchronization-related. In this tree:
   * `ppu_sysprx.cpp` lwmutex/lwcond were Windows-only; fixed.
   * The guest VM in the port's `main.cpp` was broken on POSIX; fixed.
   * The `PS3_SAMPLE` profiler and the flip timestamps are still Windows-only.
   * `win32_compat.h` already shims most Win32 sync APIs, so the fix is often just removing the guard.
2. **The guest VM must be page-aligned and ideally 4 GB-aligned.** `sys_memory_allocate`
   commits pages with `mprotect`/`VirtualAlloc`. If that fails, every allocation returns ENOMEM
   and the title "works" on NULL heaps until it segfaults.
   * Symptom: `[sys_memory] allocate(...)` with no `-> 0x4xxxxxxx` line after it, plus
     `[null-write] ... by guest-fn=...` right after boot.
3. **lwcond is a poll on Windows.** `sys_lwcond_wait` = release, `Sleep(1)`, reacquire, and
   signals are no-ops. That is correct but slow, so be careful attributing a stall to it.
4. **SPU `stop 0x110` (sys_spu_thread_receive_event) in lifted code** returns to the drain
   without advancing pc, and the lifter emits nothing at stop+4.
   * A lifted raw SPU thread waiting for events therefore spins forever. A print counter
     capped at 8 that still shows 300k lines means the int wrapped: billions of iterations.
   * It is now parked (`spu_channels.c`). A real implementation would block on the thread's
     bound queue and resume at stop+4.
5. **Two execution paths for the same SPU image.**
   * The `group_start` lifted thread, plus the `RD_SPU_INTERP` per-request interpreted re-run
     (`spu_dispatch_frame_by_queue`, from `sys_event_port_send`).
   * They have separate local stores and separate state. Always check which one is doing the
     work (`[SPU-FRAME]` = interp re-run).
6. **WWS Job Manager / SPURS job lists.** Main-thread "wait for batch" loops poll per-SPU u16
   completion counters in the workload data (`data+0x40+slot*16`, lanes `+2..+E`, unused = FFFF).
   * A wait that never ends means one lane never reported. Dump those counters over time.

---

7. **`stop 0x110` = `sys_spu_thread_receive_event` needs a real implementation for lifted raw SPU threads.**
   * Without one, the runtime re-ran the whole SPU image in the interpreter for every request, on the PPU
     thread that sent it. That made movies about 10x too slow.
   * The fix: block the SPU host thread on the queue bound with `sys_spu_thread_bind_queue` (syscall 193;
     check that it isn't a stub), reply with {CELL_OK, d1, d2, d3} in the in-mailbox, and continue at stop+4.
   * The lifter emits nothing after a stop. Interpret from stop+4 until the next lifted entry, then hand the
     pc back to the trampoline (`spu_stop`, `g_spu_recv_event_hook`).
   * A worker that "never sends its completion" under the interpreted path may be fine. inFamous' Bink
     worker throws its own event on port 0x35 once it runs as itself.
8. **Check what the D3D12 backend substitutes for textures.**
   * `SCREEN_AS_TEX` replaced any display-sized sampler with the previous frame. That is fine for one title's
     reflection pass, but fatal for a 1280x720 Bink luma plane: feedback, saturated output, ghost copies.
   * `[SCREENTEX] bound frame copy` in the log is the tell.
9. **Compile lifted SPU sources with `-msse4.1`**, not just `-O2`. `spu_helpers.h` falls back to a byte loop
   for `shufb` without `__SSE4_1__`. Look at the flags in the real `build.ninja` line, not in CMakeLists.
10. **SPURS task signals are latched bits.** Two producer wakes while the task is parked collapse into one.
    A consumer that pops one item per wake then sleeps with work queued, and its PPU partner deadlocks.
    The safety net: wake a task parked on a CellSyncLFQueue that holds items (`SPU_LFQ_AUTOWAKE`).
    The diagnostic: dump the queue line. pop1.m_h1 @+0, push1.m_h5 @+8; push != pop means it is not empty.
11. **Pace cellAudio on a clock, one block per 5.33 ms.** Consuming blocks whenever the host device has room
    makes bursts, and the game's producer (woken once per block) falls behind. `AUDIO_RATE=1` shows the
    silent % per 5 s.

12. **When the interpreter rejoins lifted code, queue the trampoline.** `spu_interp_run_until` stops at the
    first lifted entry and returns its pc, but sets no `g_spu_trampoline_fn`. Any caller that returns
    "handled" without queueing `spu_indirect_branch` silently ends the SPU run there (status still RUNNING).
    WWS policy modules hit this on every stall-and-notify interrupt (vector prologue is unlifted).
13. **Audit the hand-written microstep/interpreter decoders against the ISA.** Found in one afternoon:
    `lqa/stqa` address `i16<<4` (must be `<<2`), and `orbi/xorhi/xorbi` missing from the decoder table.
    WWS job code is NOT lifted (it is staged into LS at runtime), so the interpreter is the job's only
    execution path -- one missing opcode = the job halts and its batch never completes.
14. **A stuck pthread lock with `__cur_writer == 0` means a longjmp, not a logic deadlock.** Catch it with
    gdb (`thread apply all bt`, `p *(pthread_rwlock_t*)*(void**)&lock`). In this runtime the longjmps are
    spu_halt / spu_restart_dispatch / the irq-frame iret unwind; any of them leaving `ctx->irq_frame`
    pointing at a dead frame is fatal later.

15. **Count your SPU contexts against every fixed-size table.** The runtime had two 8-entry tables
    (MFC engines, lock-line reservation registry). SPURS policy-module contexts are persistent, one per
    (workload, SPU), so a title with 5 WWS workloads on 2 SPUs overflows them. The overflow silently
    shares one engine: tag-completion bits leak between SPUs, and an interrupt handler waiting on its tag
    spins forever. Grep for "more than %d" warnings in the log.
16. **Differential-test the SPU interpreter against the lifter** (`/home/claude/difft` pattern): random
    encodings per mnemonic, lift each as a 1-instruction function, run both from identical random state,
    compare all GPRs + LS. Cheap, and it settles "is the interpreter wrong?" in a minute.

17. **WWS job manager quick map** (Sony's SPURS "Wws_Job/..." workloads; same PM build in LBP and
    inFamous): kernel ctx LS 0x100; loadCommands LS 0xC00 (8-byte cmds, flags word: cmd=(f>>9)&7
    {Nop,ReserveBufSet,UseBuffer,UnreserveBufSets,ReqDepDec,RunJob,EndCommand}, bufSet=(f>>5)&0xF,
    buf=f&0x1F); bufferSetArray 0xDF0 (u32 = firstPage:8 pages:8 count:8 flags:8, 1 KB pages);
    logicalToBufferNum 0x11B0; job pipeline 0x12A0 loadJobState / 0x12C0 nextLoad / 0x12D0 load /
    0x12E0 run / 0x12F0 store; job code base 0x1320; workload id = LS 0x1340 hi16, SPURS EA = 0x133C;
    the job is called with `bisl $0,$5` (link 0x3258). Staged job code is NOT lifted: it runs in the
    SPU interpreter. The PM fences tag groups by issuing a 2-element dummy getl to LS 0 with a
    stall-notify sentinel `[80000000 0][0 0]` -- that is a completion interrupt, not data.
18. **When a guest SPU job can't run yet, skip it at the PM boundary rather than fake its result
    elsewhere.** Snapshot regs + PM LS at job entry, return to the link: the job manager's own
    bookkeeping (tickets, lanes, dependency counts) stays consistent (`WWS_SKIP_JOBS`,
    `WWS_JOB_TRAP_SKIP`).

19. **A lifted SPU module's entry may skip a prologue.** SPURS PMs are entered at their load base
    (0xA00); a lifter "entry" further in (WWS: 0x2BF0) skips `lqa $1,<slot>` -> wrong stack. Check what
    the real entry does before the first branch. When loading an LS quad into a register, convert
    (spu_ls_read128) -- a raw memcpy gives byte-swapped words.
20. **Device-bridge file commits can deliver a stale copy.** Stage every push under a fresh filename and
    compare md5 on the device afterwards; a link error naming a function you just added is the symptom.
21. **Offline SPU job replay** beats round-trips: dump LS + regs + the guest memory the job DMAs from at
    job entry (WWS_JOB_DUMPFILE), then rerun the interpreter on Linux with a pc log (SPU_INTERP_PCLOG).

22. **Get an RPCS3 guest-memory dump early -- it is the reference you otherwise lack.** RPCS3
    (Utilities -> Dump Guest Memory) writes a 4 GB sparse file where file offset == guest address, plus
    every SPU's LS and a manifest (thread names, pcs). Search it for byte patterns of the structure you
    are stuck on; RPCS3's heap is usually ours shifted by a constant (inFamous: 0x4xxxxxxx -> 0x3xxxxxxx).
    Then diff the SPURS instance header: inFamous showed nSpus 5/1 (+0x76) vs our 2/2 in one look.
23. **`_cellSpursAttributeInitialize` is (attr, revision, sdkVersion, nSpus, spuPrio, ppuPrio,
    exitIfNoWork)** -- not the public macro's argument order. Taking `revision` (2) as nSpus gave every
    SPURS instance 2 SPUs; WWS titles size their job batches per SPU, so jobs were built for the wrong
    machine and trapped. Check every underscore-prefixed HLE against RPCS3's signature.

24. **Branch-and-link with rt == ra: read the target first.** `bisl $0,$0` (load a function pointer into
    the link register, then call through it) is common in hand-tuned SPU code (WWS jobs call JobApi
    this way). An interpreter/lifter that writes the link before reading ra branches to its own return
    address: the call silently does nothing and the caller continues with stale r3. Symptom in
    inFamous: two logical buffers resolved to the same LS address, inputs DMA'd over outputs, job traps
    many instructions later. Audit every op where rt may alias a source (bisl, bisled, and any helper
    that writes the destination in pieces).
25. **When a job misbehaves, diff its *layout*, not only its inputs, against RPCS3.** Search the RPCS3 LS
    dumps for a known input byte pattern to learn where each buffer really lives; a different LS address
    for the same data points straight at buffer-allocation / API-call bugs. Note: low LS (0x0-0x2C00)
    in an RPCS3 dump may belong to a different workload's PM that ran later; job code/data above stays.

26. **Implement SPU double precision in the interpreter, with its own rounding mode.** "Games never use
    SPU doubles" is false: an inFamous WWS job used `dfs` right after the loading screen. SPU DP is IEEE
    round-to-nearest with denormals, unlike SP (truncate, FTZ/DAZ) -- switch MXCSR around each DP op.
    Run a "decoded ops minus implemented cases" diff on the interpreter and close it completely.

27. **SPURS passes the 64-bit workload arg in r4's preferred DOUBLEWORD** (word 0 = arg>>32,
    word 1 = low 32 bits; RPCS3 `spursKernelDispatchWorkload`: `gpr[4]._u64[1] = arg`). Don't "help" a
    PM by copying the EA into word 0: the WWS PM treats a non-zero word 0 as an *audit buffer* EA, writes
    per-SPU audit slots at `EA+0x40+16*(spuNum+hdr[0x20])` and tag-7 trace records to wherever its
    header math lands. In inFamous that trashed job list 1 on every PM entry and stalled the loading
    screen; it took a write-watch (`SPU_DMA_RANGE` + `SPU_DMA_RANGE_PUT=1`) to see the PM was the
    writer. General rule: when guest data is mysteriously overwritten, watch DMA PUTs *and* PPU stores
    to that range in one run -- the writer is often code you assumed was correct.
28. **Disassemble the PM around a logged DMA pc before theorising.** Logged pcs are often the return
    address of the brsl that issued the DMA (the lifted callee doesn't update pc). `tools/spu_disasm.py
    <img>.raw --base 0xA00` and read 20 lines: the field offsets it reads from the header tell you
    which struct it thinks it is looking at.

29. **WWS job modules can live in the EBOOT, not only in SDATA.** Scan the ELF for `C0DEC0DE`: the
    module starts 0x20 bytes earlier (`4 x ila | entryOffset | imageSize | 0 | 0 | C0DEC0DE`). inFamous
    has 21. Lift them (tools/lift_jobmods.py, base 0x4000) as soon as the game reaches the world: an
    interpreted job manager is fine for loading screens but gives ~1-3 fps in-game. The runtime picks
    a lifted module by its 16-byte header in the job code buffer; re-check that header on every
    dispatch, or the previous job's lift runs at the next job's addresses. Check which PM image id the
    title uses (LBP 2, inFamous 1) -- hard-coded image ids in shared runtime code are a trap.
30. **One FPU mode for SP, another for DP -- in BOTH execution paths.** If the interpreter switches
    MXCSR around SPU double ops but the lifted code calls the same helpers directly, the two paths
    silently disagree. Put the mode switch inside the helper.

31. **Audit log caps on hot paths once the game runs at speed.** A cap keyed on a counter that is
    reset elsewhere (e.g. per PM run) never caps. On Windows, stderr redirected to a file is
    unbuffered: each fprintf is a WriteFile under a CRT lock shared by every SPU host thread. Before
    profiling a slowdown, count lines per tag (`grep -oE '^\[[^]]*\]' log | sort | uniq -c`); anything
    in the 100k range over a minute is the first thing to cap.
32. **A new dispatch hook must go into EVERY dispatch path.** This runtime resolves SPU branches in
    three places (full resolver `spu_indirect_branch`, musttail fast path `spu_dispatch_mt.c`, drain
    resume `spu_drain.c`); the fast path handles almost all traffic. Zero log lines from a new
    hook = it is in the wrong path.

33. **When the game first reaches a real 3D scene, the renderer's caches were sized for samples.**
    Check every fixed cache (VS, PSO, texture) against a real frame (inFamous: 1271 draws, >16 VPs),
    look for eviction schemes that shift slots (invalidates everything keyed on a slot index), and
    negative-cache failures -- a PSO that fails once will otherwise be rebuilt on every draw.
    Turn on the backend's own PERF counters before optimising anything.

---

## 3. SPU / SPURS performance

### 3.1 "It runs but at 0.5 FPS": check for SPU INTERPRETER fallbacks first
* Lifted SPU code (especially streamed WWS job modules) makes indirect calls through function pointers and jump
  tables. Every target without a lifted entry goes spu_indirect_branch -> spu_smc_microstep -> the interpreter,
  which is roughly 50-100x slower. On inFamous, 21 such gaps made the world run at 0.3 fps on the cloud VM.
  Filling them gave 1.0 fps, with no scheduler change.
* How to see it: sample host stacks (gdb `thread apply all bt 8` a dozen times; `spu_interp_run_until` under
  `jobmod_*`/lifted frames is the tell), then turn on `SPU_MISS_STATS=1` (spu_channels.c). It prints the top
  (image, resident overlay, pc) misses with host ms every 10 s.
* How to fix: re-lift with the missing entries. For WWS job modules use
  `JOBMOD_EXTRA_MAP=<json {module: [addr...]}> tools/lift_jobmods.py ... --symbol-prefix <port's original prefix>`
  (overlay id 200+i = manifest index i). Iterate: fixed gaps uncover the next ones. Before replacing anything,
  verify that a re-lift without extras is byte-identical to the shipped lift.

### 3.2 SPURS kernel throughput (generic)
* A real SPURS instance runs its workloads on nSpus SPUs IN PARALLEL. Emulating it with one host thread per
  instance makes one heavy workload (audio double-buffer, ~70%+) starve the rest. Run one kernel thread per
  virtual SPU and claim a workload atomically before running it (never two SPUs on a maxContention-1 workload).
* Counters the SPU side bumps while a policy module runs (polls/exited) must be thread-local once PMs run on
  several host threads.
* Measure before guessing: SPURS_STATS=1 (runs / busy / skipped / ms per workload every 5 s).

### 3.3 Parallel SPURS kernel (SPURS_PAR_SPUS): ~1.6x, but it deadlocks -- currently OFF
* One host kernel thread per virtual SPU (min(nSpus,6)), workloads CLAIMED with a compare-exchange so a
  maxContention-1 workload never runs on two SPUs, per-thread pass counters, busy/idle per instance,
  `g_spurs_pm_polls/exited` thread-local (`SPU_PM_TLS`).
* Measured on the 2-core Linux VM: in-world 0.3 -> 0.5 fps, CTaskMgr workloads 17-25 -> 400-770 runs/5 s.
* BUT it deadlocks intermittently: the main thread spins at 0x8E3898 on `m_joblistMesh` (0x7DF000) and the
  frame stays at 1 draw forever. The user hit it twice in a row. Unsolved; the files are in
  `_xfer\par_attempt_1004\` and the Linux `par` tree. The device has the ORIGINAL single-kernel files.
* Next step when picked up again: dump the job-list rows at 0x7DF000 when stuck, and compare which lane never
  reports (2.6). Likely a lane/ticket ordering assumption the single-thread kernel satisfied by accident.

### 3.4 Lift-gap filling, measured (inFamous)
* Three rounds of SPU_MISS_STATS -> JOBMOD_EXTRA_MAP -> re-lift added 32 entries in 14 job modules
  (`spu/jobmods_extra_map.json`).
* Linux (2 cores, same flags): in-world 0.30 -> 0.93-0.99 fps; "world loaded" 329 s -> 201-277 s.
  Windows: in-world ~1.6 -> ~5 fps (with the renderer fixes of chapter 5).
* What is left cannot be fixed by lifting: ovl 209 runs RUNTIME-GENERATED code at 0x21140/0x22140 (same
  patterns 0x1000 apart) and a few out-of-module PCs (0x18FF8, 0x35xxx). Total interpreter time after the
  three rounds: ~300 ms per 10 s (~3% of one core) -- no longer the bottleneck.

---

## 4. Diagnostic recipe for "it boots but the screen is black"

1. **Is anything being presented?** Run with `GCM_FLIPCOUNT=1` and count `[flip]` lines over time.
   * Flips stop: the guest stopped submitting (stall or deadlock).
   * Flips climb: it's the renderer.
2. **Where is everyone?** Use `INFAMOUS_HANGDUMP`-style snapshots: per thread, the HLE it is
   parked in plus its guest lr/r3/sp.
   * A thread "in no HLE" with a moving lr is spinning in guest code.
   * Take several snapshots to tell a deadlock from a slow loop.
3. **Who holds the lock?** `LWM_TRACE_EA=<lwmutex>` gives the lock/unlock history with stack
   return addresses. Pair locks with unlocks to find the acquisition that never got released.
4. **What is the spinner waiting on?**
   * Find the call site: `grep "ctx->lr = 0x<lr>;" recompiled/*.cpp`.
   * Read the loop and identify the object (often `*(*(r2-OFF)-OFF2)`).
   * Then dump it with `*EA+off` dereference dumps.
5. **Name threads** from `sys_ppu_thread_create name="..."` in the log. It turns the hang table into a story.
6. **Check races.** Run the same build twice. If the results diverge (e.g. a "not ready, retrying"
   patch line appears in one run but not the other), the divergence point is the lead.
7. **Compare against Windows evidence** (instruction counts per SPU job are a great fingerprint;
   identical counts mean identical code path).

---

8. **Black frame with a healthy draw count: bisect with captures, not theories** (D3D12 backend, env-only):
   * CELLMARK_DUMP=3 + CELLMARK_DUMP_MINDRAWS=1000 saves the presented frame; RTT_SAVERT=<hex rt> (+_AFTER=<s>)
     saves an offscreen RT; RT_OFFDBG=1 lists every surface setup (disp=1 = display buffer).
   * RT_CLEARDBG=2 (+DEPTH_OFF, CULL_OFF, CMASK_FORCE): all magenta = nothing rasterised -> check vertex
     data (VP_ATTRS[_FP|_DUMP]), matrices (VPC_DUMP_FP), and **the per-frame vertex budget** (PERF `vtx` count
     sitting exactly at a power-of-two-ish cap = draws silently truncated).

---

## 5. The D3D12 RSX backend: architecture and every lesson learned
File: `ps3recomp/libs/video/rsx_d3d12_backend.c` (~7.5k lines, C with COM). Companion files:
`rsx_commands.c` (FIFO method parser), `rsx_vertex_fetch.c`, `rsx_fp_decompiler.c`, `rsx_vp_decompiler.c`,
`cellGcmSys.c` (flip).

### 5.1 How it works (read this before changing anything)
* **Record, then replay.** The FIFO parser calls `d3d12_draw_arrays` / `d3d12_draw_indexed` per DRAW method.
  Each call converts the guest vertices on the CPU into an upload buffer and appends a `D3D12DrawRecord`
  (vertex offset/count, textures, render targets, blend/cull/mask, viewport, which constant slot, ...).
  `render_frame()` runs once per frame (at flip or clear boundary): prepass over all records (resolve render
  targets, write per-draw SRV windows, find pipelines), then replay them into one command list.
* **Frame parity.** Upload streams (vertices, per-draw VS constants `vp_cb`, per-draw FP constants `vp_fpcb`)
  are double-buffered by `vp_parity`; `render_frame` also calls `wait_for_gpu()` at its start, so the
  previous frame is finished before its buffers are reused.
* **VP path.** Every vertex is expanded CPU-side (indices resolved, quads/strips/fans -> triangle lists) into
  16 float4 attribute slots (ATTR0..15 at i*16 in the input layout); the guest vertex program is decompiled
  to HLSL (`vp_get_vs`, cached by program hash) and the fragment program likewise (`vp_get_fp_pso`).
* **Per-draw constant slots.** `vp_record_cb(slot)` snapshots the VP constant bank (b0, 8448 B) and the FP
  slot (b1, 1280 B: rsx_texscale[4], rsx_alphatest, fp_constants[64] from float4 index 5) at RECORD time.
  Records carry `cb_slot`, because some passes reorder records.
* **Per-draw SRV windows.** Draw d's 16 texture units live at heap slot `DRAW_SRV_BASE + d*16`. Other ranges:
  RT_SRV_BASE (offscreen render targets), VPTEX_SRV_BASE (uploaded guest textures, VP_TEX_SLOTS=4096 since v32f).
* **Offscreen render targets** are aliased: one VRAM offset is used at several sizes/formats per frame, so
  they are keyed by offset+w+h+format (`off_rt_get`), and `off_rt_latest` says which alias was written last.

### 5.2 Per-frame budgets and caches (current values)
| Thing | Was | Now | Where |
|---|---|---|---|
| Draw records | 2048 | 16384 (`MAX_DRAWS`; runtime `s_max_draws` halves if the CB allocation fails) | records, b0/b1 slots, SRV windows |
| VP vertex store | 393,216 then 2M fixed | chunks of 1M vertices (256 MB) per parity, up to 12, allocated on demand | `vp_reserve`, `s_vpc_*` |
| Bytes per vertex | 256 | 16 x (highest VP input register + 1); inFamous world VPs: 144-192 B | `vp_pack_begin`, `VP_PACK` |
| VS cache | 16, then 256 (memmove) | 2048, round-robin in place | `VP_VS_CACHE` |
| Pipeline cache | 16, then 256 (FIFO memmove) | 4096, hashed index, round-robin, deferred release | `VP_FP_CACHE`, `s_fpi` |
| Texture units | 4 | 16 | `RSX_D3D_TEX_UNITS` |
| Distinct textures/frame | 4, 96 | 256 | `VP_TEX_SLOTS` |
* inFamous' real demand (title screen = the city behind the logo): 10,236 BEGIN/END batches, ~17,000 DRAW
  calls, 2.62M vertices (all triangle lists), ~168 MB packed, ~600-2000 distinct pipelines, 69-82 VSs.

### 5.3 Black screen with a "real" frame: check every per-frame CAP first (summary)
* A recorded-then-replayed renderer has fixed per-frame budgets (draw records, vertex buffer, constant slots).
  When one fills, the LAST draws of the frame are dropped silently -- and those are the lighting/post/present
  passes, so the whole screen is black while thousands of draws "succeed". Tell-tale: a frame counter that
  sits on a round number (title bar `draws: 2048`, PERF verts = exactly the buffer size).
* Measure the real demand cheaply off-GPU: count BEGIN/END batches and vertices per flip in the command parser
  (FRAME_DRAWS=1 prints them). inFamous' city: ~10.2k batches, 17k draw calls, 2.6M vertices.
* Fix by growing on demand (chunked upload buffers, records remember their chunk) rather than raising one
  constant; a single huge upload resource can hit the per-resource size limit.
* When you add a field to a draw record, grep EVERY place a record is created (draw_arrays quads/tris/strips,
  draw_indexed, clears): a field set on only some paths keeps the previous frame's value on the others.
  (inFamous: indexed draws kept a stale vertex-chunk index -> garbage geometry -> 5 s frames.)
* After raising the draw cap, re-check every per-frame CACHE (shader/pipeline caches) against the new draw count.
  inFamous: 256-entry FIFO pipeline + VS caches were fine at 2048 draws and thrashed at 10k (11 s frames, all
  CPU in recompiles). Use big hashed caches, never memmove-evict (it re-keys every slot), and never Release a
  PSO that the open command list may have bound -- defer it until after the GPU fence.
* Expanding every vertex to 16 x float4 (256 B) is 4x more memory than the VP reads; pack to the highest input
  register the VP reads (rsx_vp_analyze_inputs) and set the VB stride per draw.

### 5.4 Vertex memory: grow on demand, never truncate silently
* A frame that does not fit used to lose its LAST draws (lighting, post, present) with no error -> black.
  `[VPVB] OVERFLOW: frame requested N verts in M draws, buffer holds K; D draws truncated` now prints.
* Chunks: `vp_reserve(need)` (called right before a draw captures its record offset) moves to the next chunk
  of the current parity when the draw does not fit, allocating it the first time (`[VPVB] grew: parity P now
  has N chunks`). Records store `vb_chunk`; replay binds a per-draw vertex-buffer view.
* One giant upload resource is a bad idea: per-resource size limits (~min(2 GB, 1/4 VRAM) class) and an
  all-or-nothing allocation. Chunks also let a later frame keep using what the first big frame allocated.
* **Bug we shipped and fixed:** `d3d12_draw_indexed` never set `vb_chunk` -> indexed draws (most of the
  world) read vertices from a stale chunk -> garbage triangles -> 5-second frames and a smeared picture.
  Rule: when a record gets a new field, grep EVERY record-creating site (quads, tris, strips/fans, indexed,
  clears). Python `replace` on an indentation-sensitive pattern can also hit the wrong (nested) site: check
  `grep -n -A2` afterwards.

### 5.5 Packed vertices (VP_PACK)
* The input layout keeps ATTRi at i*16 bytes. A draw stores only slots 0..N-1 with stride N*16, N = highest
  input register the VP reads + 1 (`rsx_vp_analyze_inputs`; inexact -> 16; cached per program hash). Slots
  the VS does not read alias the next vertex, which is harmless; reads past the window return 0.
* Replay binds `BufferLocation = chunk + offset, StrideInBytes = N*16` per draw and draws from vertex 0.
* Measured: city frame ~670 MB -> ~170 MB per frame of upload memory (written by the CPU, read by the GPU).
* `VP_PACK=0` restores the fixed 256-byte vertex for A/B tests.

### 5.6 Shader and pipeline caches (the 11-second frame)
* Symptom: `[SLOWFRAME] 14206 ms: GPU wait 0 ms, render_frame CPU 11880 ms` with memory far below budget.
  Cause: caches sized for samples (256) thrash at 10k draws -> hundreds of decompile + D3DCompile +
  CreateGraphicsPipelineState per frame.
* Rules learned:
  * Size caches for a real frame and use a hashed lookup (a linear scan of 4096 entries x 20k lookups/frame
    is itself measurable).
  * Never evict with memmove: it shifts every slot, which re-keys everything that refers to a slot index
    (pipelines keyed on vs_idx, records holding vs_idx). Replace round-robin in place.
  * Never Release a PSO (or any resource) that the command list being recorded may already reference:
    `defer_release()` it until after the next `wait_for_gpu()`.
  * Resolve the pipeline once per draw (prepass stores `pso_memo` for `s_frame_no`; replay reuses it).
  * Persist compiled shaders: `cached_compile()` stores D3DCompile output as `shadercache\<hash>_<target>.cso`
    (hash of HLSL text + target + entry + flags). `SHADER_DISK_CACHE=0` disables; `[SHADERCACHE] N hits, M
    compiles`. Second runs skip the compiles.
  * Vertex-program identity = hash of ONE program (start slot .. END instruction, `vp_hash_program`), not of
    the rest of the microcode store (that re-keyed unchanged programs whenever another program was rewritten
    and hashed 8 KB per draw).
* Diagnostics: `[SLOWFRAME]` prints pipeline/VS compiles per slow frame and cache fill; `[CACHES]` every 15 s;
  `[PSOCACHE] full` / `[VSCACHE] full` if a cache fills; PERF `pso ... N calls M MISS`.

### 5.7 Pipeline identity and fragment-program constants (the black title screen)
* RSX fragment programs carry inline constants right after the instruction that uses them; titles re-patch
  them per draw and re-upload identical programs to new addresses (inFamous does both).
* What went wrong, in order:
  1. The backend called the decompiler in LITERAL mode (constants baked into HLSL) while the pipeline key
     hashed only the instruction words (`rsx_fp_code_hash`) plus the ADDRESS. A comment claimed constants
     came from b1 -- stale, from an older decompiler. Same-address programs with new constants kept a stale
     shader (wrong colours/blur).
  2. Keying by address made the cache grow forever (new addresses every frame: 50-180 compiles per frame
     on a static screen, 0.5 fps).
  3. Keying by code alone (address dropped) made programs that differ only in constants share one shader:
     black title screen.
* Fix: decompile in BUFFERED mode (`rsx_fp_decompile_buffered_ex`), re-declare b1 as
  `float4 rsx_b1_pre[5]; float4 fp_constants[64]; float4 fp_alpha;` so the constants land at float4 5 where
  `vp_record_cb` writes them, fill them per draw from the draw's own ucode, and key on code + constant count
  (`fp_scan`). Programs with > 64 constants or `FP_CONSTBUF=0` use literal mode keyed on ALL bytes.
* The walkers must agree on what an "instruction with a constant" is. The decompiler and
  `rsx_fp_collect_constants` count a CONST source on ANY instruction (branches included);
  `rsx_fp_extract_consts` and `rsx_fp_code_hash` skip branch instructions. Mixing them misaligns slots.
  The backend now has its own `fp_scan`/`fp_fill_consts` that follow the decompiler.
* Unit-test the decompiler path on Linux with the hand-assembled programs in
  `libs/video/tests/test_fp_decompiler.c` (MAD with an inline constant etc.) -- it caught nothing wrong this
  time, but proves the splice before a round trip.
* Debug overrides that inspect one program by address (FP_ONE, FP_KILL, FP_SHOW, FP_IDCOLOR, FP_TEX, FP_PICK,
  FP_FORCE, FP_KEY_ADDR) switch the pipeline key back to include the address.

### 5.8 Per-draw descriptor writes (SRV dedupe)
* 16 units x 10k draws = 160k CreateShaderResourceView per frame (~25 ms). `srv_write_ex` keeps a shadow of
  what each per-draw slot holds and skips identical writes; any resource release bumps `s_srv_gen`, which
  invalidates the shadow (a freed resource's address can be reused). `SRV_DEDUPE=0` disables.
* Observed: in inFamous the generation is bumped every frame (render targets/texture slots get recycled), so
  skips are ~0 for now -- the next step is to bump only when a resource that was actually written into a
  per-draw slot is released.

### 5.9 GPU hangs / DEVICE_REMOVED
* Log `GetDeviceRemovedReason` (0x887A0006 = HUNG, which can also be a page fault on NVIDIA).
* Turn on **DRED** before device creation (`D3D12_DRED=1` in rsx_d3d12_backend.c). It needs no SDK debug layer.
  The `[DRED]` report gives the last completed op per command list and the page-fault VA, with a
  freed-vs-live allocation flag.
* Classic cause: releasing a resource that the OPEN command list already references. `wait_for_gpu()` only
  covers lists already submitted. Defer releases to the next frame start.
* PS3 titles ALIAS render targets (one VRAM offset, several sizes per frame). Key surface caches by
  offset+size+format, never by offset alone.

### 5.10 Video memory
* `[VIDMEM] local a/b MB, system(non-local) c/d MB (usage/budget)` every 15 s and on slow frames
  (IDXGIAdapter3::QueryVideoMemoryInfo). inFamous on an 8 GB RTX 4060: ~0.1 GB local, ~0.9 GB system --
  nowhere near the budget, so memory was ruled out in one run. Upload heaps count as SYSTEM (non-local).
* The adapter line on stderr: `[D3D12] adapter: <name> (VRAM, shared)`.

### 5.11 Known open renderer issues (inFamous)
* The title screen was blurry/smeared before the 5.4/5.7 fixes; re-check after them.
* `rsx_texscale` (unnormalised-texture scaling) is filled in b1 but the current decompiler never references
  it; the cube-map rewrite in `vp_get_fp_pso` searches for a `.xy * rsx_texscale[N].xy` tail that no longer
  exists. UNNORM textures may be sampled wrongly.
* Bink video: the 1280x720 luma plane was once replaced by the previous frame (`SCREEN_AS_TEX`, see 2.8).
* CPU vertex expansion is ~25% of frame time (~58 ms of ~233 ms at the title screen).

---

### 5.20 Predicated FP writes must be selects, not lerps (inFamous v38)
* RSX fragment instructions can be gated by the condition register; a masked-off component is simply NOT written.
  Emitting that as `dst = lerp(dst, value, mask)` is wrong whenever the unselected value is inf/NaN: lerp(a, NaN, 0) = NaN.
  Titles guard exactly the dangerous ops this way (pow/log of a dot product behind `N.H > 0`, rsq behind a length test),
  so the guard itself produced NaN -> the output NaN guard -> black pixels. Use a per-component select
  (`(_p != 0) ? v : dst`, fxc ps_5_0 vector ?: = movc). Same rule for any "blend by a 0/1 mask" trick in a decompiler.
* Symptom pattern: a G-buffer target whose RGB is exactly 0 while its alpha (computed by a separate path) is sane = NaN
  guard. Before theorising, simulate the decompiled program numerically with the captured inputs (a small HLSL-subset
  interpreter did it here) and build a diagnostic that colour-codes WHICH input is non-finite instead of guessing.
* The DXC Linux release (github.com/microsoft/DirectXShaderCompiler, linux_dxc_*.tar.gz) compiles generated HLSL in the
  cloud container; use `-HV 2018` to get fxc-era rules (vector ?: allowed).

### 5.21 Texture plumbing checks that found three lighting bugs in one night (inFamous v41-v44)
* Format WHITELISTS drift: the decoder (rsx_texture_layout.c) supported formats that the bind path and the prepass upload
  path silently refused ("unit keeps its previous texture"). grep every place a format byte is tested; one list, not three.
* Single/dual-channel formats need their own remap lanes. RSX remap sources index {A,R,G,B}; for an R8 resource B8 must be
  presented as {ONE,R,R,R} (RPCS3 VKFormats.cpp get_component_mapping, "ARGB format"), else a remap like 0xAAFF (all <- B)
  reads a component the resource does not have = 0. inFamous' light RAMP was B8 -> lighting ~10x too dark.
* Pass the CUBE mask into the FP decompiler. A cube SRV read through a Texture2D declaration is undefined (~0): the ambient
  irradiance cube vanished -> everything out of direct light pitch black. A post-decompile string fix-up that matches an old
  emitter pattern silently does nothing after the emitter changes -- assert it matched.
* The manifest must list ALL texture units; the bugs above sat on units 4-6 while the capture printed 0-3.
* Shipping an untested texture-format upload can remove the device (Y16_X16 in v42): keep new upload paths behind a switch.
* Diagnose "flat/ghost geometry" by measuring, per pass, which pixels change and the stored depth there (sky = far): it
  separated a coarse-world LOD pass (overwrote near geometry) from glass panes (drawn only over sky = orphaned).

### 5.22 A cached copy registered at the source's own address hides the source (v49, the "title-screen city overlay")
* Symptom: a ghost of the *start-menu* city (its silhouette, billboard edge, window grid) lit into every in-game
  frame; see-through NPC limbs; lighting that ignores what is really on screen. Five wrong theories (depth range,
  depth bounds, alpha test, colour-target NONE, shadow compare order) were tried first.
* Cause: depth sampled as A8R8G8B8 (deferred lights rebuild position from 0x1010000) is served from a colour copy
  that is an ordinary OffRT created **at the depth's own offset**. The prepass rule "a real colour target at this
  address wins over the depth path" then found the copy itself after the first conversion, so the copy was never
  refreshed: frozen at the title screen forever. The log showed it: exactly one `[ZETA] converted ...` line per run.
* Fix: `zs_is_conv_slot()` -- a slot that is some zeta's `conv_rt` does not count as a colour target.
  `ZCONV_STALE=1` restores the old behaviour.
* How it was found: overlay the edge map of the title-screen backbuffer on the in-game frame; the ghost lined up
  pixel for pixel, so the culprit had to be a texture holding title-screen data -> diff the light passes to find
  the first draw that adds the ghost -> list its texture units -> the one backed by a cache.
* General rule: any cache/copy keyed by the guest address it mirrors must be excluded from "is something else at
  this address?" lookups, and every "converted once" log line deserves a count check.

### 5.23 RSX semaphore ACQUIRE must really wait (v50, "see-through limbs")
* Symptom: skinned characters missing their most-animated parts (knees, forearms), NPC limbs see-through, flicker.
  The holes are already in the G-buffer and depth -> geometry, not shading.
* Cause: SPU skinning writes the vertex positions into local memory and releases a label. The PPU's
  cellGcmSetWaitLabel puts an NV406E ACQUIRE (0x64 offset / 0x68 value) into the FIFO. An ACQUIRE treated as
  a no-op draws from half-written vertex buffers.
* Implementation: don't block a thread forever. Spin briefly, then stop the drain pass without consuming the method,
  so the next pass re-checks. Skip the wait after a timeout and log it, so a label nobody writes cannot wedge the FIFO.

### 5.24 SPU floats have no Inf/NaN -- clamp exponent-255 operands ("approximate xfloat", v52)
* SPU single precision treats exponent 255 as a normal number (up to ~6.8e38), and frest/frsqest(0) return
  0x7FFFFFFF on purpose. Plain x86 float math makes those values Inf/NaN, and 0 * max = NaN.
* Symptom in inFamous: whole skinned segments (knees, thighs, forearms: the multi-bone joints) missing from
  every character, while the vertex data that arrives at the RSX is otherwise clean. Any NaN in SPU-produced
  data is proof, because real hardware cannot make one.
* Fix: clamp float operands with exponent 255 to +-FLT_MAX in the SPU helpers. This is cheap and matches RPCS3's
  default mode. Keep a switch (SPU_XFLOAT=0) for A/B tests.
* Diagnostic that settled it: dump the converted positions and indices of the character draws in the frame
  capture (CAP_VDUMP), then render them offline as wireframes. Missing pieces in the INPUT data rule out the
  renderer in one step.

### 5.25 Two switches that must not contradict each other (inFamous v88, "too bright, no shadows")
* SHADOWS=1 (real shadow compare) + SHADOW_LIT=0 looked like "correct rendering", but the texture-bind path accepted
  depth formats only under SHADOW_LIT, so every shadow-map bind was dropped and the unit kept its previous texture.
  The sun shader's shadow lookup then sampled a lighting ramp (~0): no direct sun anywhere, only the sky ambient. The
  game looked flat, cold-blue and washed out.
* Check in a capture: count draws that sample the shadow map's format (inFamous 0xB0 at 0x0F340000) vs draws that
  render into it. Thousands of caster draws with zero readers means the binding is lost on our side.
* Rule: a feature switch must be honoured at EVERY layer it touches (record, bind, prepass, PSO). Grep each env
  helper's call sites when a launcher combines switches in a new way.

### 5.26 RSX texture-unit transforms: unsigned remap (bx2) and gamma (inFamous v89/v93)
* TEXTURE_ADDRESS bits 12-15 = unsigned_remap (1 = BIASED: texel*2-1), bits 20-23 = gamma (sRGB -> linear per channel),
  bits 24-27 = signed_remap, bits 28-31 = depth-compare func. The RSX applies these in the texture unit, so the
  fragment program does NOT contain the *2-1. A deferred renderer that normalises tex(normal).xyz directly is the tell.
* Missing bx2 = G-buffer normals stay in 0..1: flat lighting, wrong N.L and wrong shadow-projection offsets.
  inFamous looked flat, cold and washed out until it was emulated.
* Expand RGB only. Alpha in a G-buffer normal target carries material data in 0..1. Expanding it turned decals'
  alpha 0 into -1 and painted black squares, so keep alpha untouched unless a title proves otherwise.
* Implementation pattern: a per-draw, per-unit mode in the PSO key, plus a textual wrap of that unit's Sample /
  SampleBias / SampleLevel calls in the generated HLSL (rsx_txf). Log each distinct (unit, fmt, remap, gamma) once.

### 5.27 MRT state is three registers, and D3D12 ignores per-target state without IndependentBlendEnable (v90/v91)
* NV4097_SET_COLOR_MASK_MRT (0x0370): one nibble per MRT 1..3 (a=bit0 r=bit1 g=bit2 b=bit3; RT0 keeps SET_COLOR_MASK).
  NV4097_SET_BLEND_ENABLE_MRT (0x036C): bits 1..3 = MRT 1..3 blend enable, using the global blend factors, even
  when RT0 blending is OFF.
* Deferred decals write albedo straight but blend or mask the normal target to keep its alpha (material data).
  Without that: black squares around every decal after lighting.
* D3D12: per-RT RenderTargetWriteMask / BlendEnable are silently ignored unless
  BlendState.IndependentBlendEnable = TRUE. A whole build (v90) shipped a correct-looking fix that did nothing.
* Grep `[RSX-UNK]` method lists early: 0x0370 / 0x036C had been logged as unknown for days.

### 5.28 Shadow compare direction: decide it with correct inputs, then add a bias (v48 -> v91/v92)
* A compare order chosen while other inputs were broken (here: un-expanded normals) can look right for the wrong
  reason. After v89 fixed the inputs, the v48 "flip" lit exactly the caster silhouette (inverted). Re-validate
  the compare from a capture: diff the light buffer before/after the sun pass and look for the caster shape.
* With the correct order, sun-facing surfaces show acne stripes (self-shadow at depth == reference). A small
  constant bias on the reference (0.0015 in 0..1 depth for inFamous' cascades) removes it.

## 6. Input (cellPad)
### 6.1 "Press Start" ignored at low frame rates
* Titles often read the pad once per frame. At a few fps a key tap falls between two reads and is never
  seen. Poll the host on its own thread and latch presses until the next delivered packet (cellPad.c).
* Details: `ps3recomp/libs/input/cellPad.c`. A host thread polls XInput + the keyboard every 4 ms
  (`[cellPad] host poll thread started`, `PAD_NO_THREAD=1` disables) and ORs every pressed button into a
  per-port latch; `cellPadGetData` reports `held | latched` and clears the latch only when it delivers a
  packet with len > 0 (`[cellPad] delivered a latched press 0x....` logs the first few).
* Evidence it was needed: `[cellPad] heartbeat` showed ~4 GetData calls per second at 4 fps, and only
  2 of the user's presses ever reached the game.
* Keyboard map (window must have focus): Enter=START, Tab=SELECT, arrows=D-pad, Z=Cross, X=Circle,
  A=Square, S=Triangle, Q/W=L1/R1, 1/2=L2/R2. With an XInput device present the keys are merged into port 0.
* Button encoding inside the toolkit: one u16, low byte = DIGITAL1 (SELECT 0x1, L3, R3, START 0x8, UP 0x10,
  RIGHT, DOWN, LEFT 0x80), high byte = DIGITAL2 (L2, R2, L1, R1, TRIANGLE 0x10, CIRCLE 0x20, CROSS 0x40,
  SQUARE 0x80) -> e.g. 0x4000 = Cross, 0x2000 = Circle, 0x0008 = Start.
* Test helpers already in cellPad.c: PAD_AUTOPRESS, PAD_SCRIPT="<sec>:<mask>,...", YDKJ_INJECT_PAD.

---

### 5.13 Depth surfaces and depth read back as a texture (the intermittent black screen)
* RSX keeps a depth surface (zeta) per VRAM offset; it persists across passes and frames and is cleared only
  by CLEAR_SURFACE with mask bit 0/1. Deferred renderers read it back as a TEXTURE: inFamous samples its zeta
  (0x1010000) as a 1280x720 A8R8G8B8 texture in lighting, fog and post. An A8R8G8B8 fetch of a D24S8 word
  returns A = depth[23:16], R = depth[15:8], G = depth[7:0], B = stencil (PS3 shaders decode `dot(t.arg, ...)`).
* A backend that keeps depth only in the GPU and lets the texture path upload guest VRAM gives the shader
  whatever stale bytes are there -> black (zeros) or a dim/smeared image (leftovers of earlier screens), and it
  CHANGES BETWEEN IDENTICAL RUNS. If a picture comes and goes with no code change, check whether any sampled
  texture offset equals the zeta offset (`zeta=` in RT_OFFDBG, `t<n>=` in the rsxcap manifest).
* Implementation (rsx_d3d12_backend.c, "Depth surfaces (zeta)"): per-(offset,size) depth buffers
  (R24G8_TYPELESS), records carry the zeta, no depth wipe on target switch, honour the clear mask, guest depth
  test/write/func in the pipeline key, and a fullscreen conversion pass into an R8G8B8A8 copy right before a
  draw that samples the zeta offset. Env: ZETA_SURFACES=0, CLEAR_MASK_FIX=0, GUEST_DEPTH_STATE=0, ZCONV_ORDER=1.
* Titles point the zeta at a COLOUR surface or a display buffer for passes that do not use depth (inFamous
  does it for most post passes). A zeta offset equal to an active colour target / display buffer is NOT a
  depth surface; and when a texture offset has a real colour render target, the colour target wins. Getting
  this wrong turns every G-buffer read into converted depth (flat neon colours).
* The same holds for DISPLAY buffers: titles render intermediate passes into them and sample them (inFamous:
  display buffer 1 = light accumulation, sampled by later passes and bloom). Treat display buffers as normal
  render targets and copy the flipped one to the swapchain; never let "display surface" mean "draw straight
  to the backbuffer and forget it". General rule: ANY surface the GPU writes can be read back as a texture.
* Checklist for any renderer port: never clear depth except on a guest clear; never ignore the clear mask (a
  depth-only clear that also clears colour erases pictures); carry the guest's depth state into pipelines; and
  expect depth (and stencil) to be sampled as colour.
* Tool used to find it: the backend's own frame capture `RSX_CAP=start:count:stride` + `RSX_CAP_MINDRAWS=N`
  (manifest of every op with targets/shaders/textures + BMPs of all RTs). Read the op list, group consecutive
  ops by target, then follow what the final composite samples back to an address nothing ever renders to.

### 5.12 Self-bisect inside one run (when each round trip costs the user minutes)
* When a regression has several candidate causes and every test needs the user to build and run, make the
  build bisect itself: runtime flags for each candidate, a controller that flips them cumulatively on a timer
  once the interesting state is reached, a log line per phase, and a frame capture per phase (inFamous:
  `BISECT=1`, phases every 20 s after the first >= 500-draw frame, `bisect_p<N>_*.bmp` via the existing
  CELLMARK dump path). One run then answers what would otherwise take four.
* Caveats learned the hard way: capture only REAL frames (>= N draws; near-empty clear-boundary presents are
  black anyway), and make sure the phases really reproduce the last good configuration. Even then a bisect
  only finds CODE regressions: inFamous' black screen bisected to nothing because pure v8 was black too --
  the cause was nondeterministic input (stale guest VRAM read as the depth texture, 5.13).

---

### 5.14 Depth range: a viewport with min == max is NOT "no viewport" (the flat far-LOD buildings, v34)
* cellGcmSetViewport(x, y, w, h, min, max, scale[4], offset[4]) writes VIEWPORT_SCALE/OFFSET (z scale =
  (max-min)/2, z offset = (max+min)/2) AND SET_CLIP_MIN/MAX (0x0394/0x0398). A pass drawn with [1,1] (or [0,0])
  has z scale 0: every vertex lands on the far (near) plane, so with depth test LEQUAL it only fills pixels the
  scene left at the clear value. inFamous draws its far-LOD city and sky that way, blend OFF, with a 2-instruction
  "output tex0" FP -- right after the deferred lighting.
* The backend's VS epilogue used "z scale == 0" to mean "the guest never programmed a viewport" and substituted
  scale 1 / offset 0. The meshes kept their real depth and painted flat, unlit buildings over the lit frame. If
  the picture has flat unlit geometry IN FRONT of correctly lit geometry, check the depth range first.
* Fix: scale 0 with offset != 0 (or clip_min == clip_max) -> pos.z = offset * w. Do not also put the range in the
  D3D viewport Min/MaxDepth: the epilogue already applies the guest scale/offset, so a non-[0,1] range would be
  applied twice (GUEST_DEPTH_RANGE=1 does that, default off). Switch: ZFLAT=0. Log: `[ZFLAT]`, `[RSX] depth range`.
* The capture manifest prints `z scale S offset O` per draw; a draw with scale 0 offset 1 is a far-plane pass.

### 5.15 Shadow maps: depth textures with compare (v34)
* A sampler whose format is DEPTH24_D8 / DEPTH16 (+float) (base 0x90-0x93) is a shadow lookup on RSX: the
  texture unit compares and returns the 0..1 result (2x2 PCF when filtering), the FP just reads it. The compare
  function is TEXTURE_ADDRESS bits [31:28] (NEVER LESS EQUAL LEQUAL GREATER NOTEQUAL GEQUAL ALWAYS) and it is
  (CORRECTED v48: for inFamous the GL order "ref FUNC texel" is right -- with "texel FUNC ref" the cascades lit
  only the shadowed pixels = ghost buildings; check one cascade's lit mask against its shadow map) (inFamous uses GREATER;
  UNVERIFIED on this port until play36 -- SHADOW_FLIP=1 swaps it). Reference = texcoord.z (TEX) or z/w (TXP).
* Implementation: bind the zeta surface itself through an R24_UNORM_X8 SRV (no colour copy), transition it to
  PIXEL_SHADER_RESOURCE right before the sampling draw (the normal target-rebind path takes it back to
  DEPTH_WRITE), and rewrite the decompiled sample into GatherRed + compare + bilinear weights
  (fp_shadow_rewrite). The unit mask and zfuncs must be part of the pipeline key.
* Only take this path when the zeta has the SAME size as the texture and the draw does not render into that
  zeta; the same VRAM offset is often reused at another size (inFamous: 0x0F340000 is the 1024x1024 sun shadow
  map and later a 512x288 half-res depth).
* Before v34 the unit was forced to 1.0 ("lit") and SHADOW_SKIP dropped the caster passes -- 7042 of 10272
  draws of a city frame. Real shadows cost those draws again. Switches: SHADOWS=0 (old), SHADOW_FLIP=1.

### 5.16 Black G-buffer normals on one mesh = NaN output (open, inFamous' Cole)
* The decompiled FP ends with `_out.tN = (_o == _o) ? _o : 0` (NaN guard). A tangent-space normal shader whose
  vertex normal/tangent inputs are 0 normalizes a zero vector -> NaN -> the guard writes exactly 0 = black in
  the normals target while the albedo is fine. Look at the VS outputs / vertex attribute formats of that mesh
  (capture vp/vs_NNNN.hlsl lists them), not at the FP.

### 5.17 Depth bounds test (v35) -- and a correction to 5.14
* 5.14's "depth range [1,1]" diagnosis was WRONG for inFamous (z scale was 0.5/0.5 everywhere); the fix stays
  (correct RSX semantics, harmless). Check the manifest's `z scale`/`offset` BEFORE theorising about depth range.
* NV4097_SET_DEPTH_BOUNDS_TEST_ENABLE 0x0380, _MIN 0x0384, _MAX 0x0388: a fragment is dropped when the depth
  already STORED at its pixel is outside [min, max] (independent of the depth test). Engines draw far-LOD copies
  of the world over the whole frame and let the bounds test keep them only where the stored depth is far; without
  it the LOD z-fights the real geometry -> "transparent"/flat buildings over the scene.
* D3D12: D3D12_OPTIONS2.DepthBoundsTestSupported, pipeline via a state stream with DEPTH_STENCIL1
  (DepthBoundsTestEnable) -- the plain GRAPHICS_PIPELINE_STATE_DESC cannot express it -- and
  ID3D12GraphicsCommandList1::OMSetDepthBounds per draw. Stream subobjects: each starts 8-aligned, the payload
  follows the 4-byte type at its own alignment (8 for pointers/bytecode/input layout, else 4).
* Generic lesson: when geometry that should be masked covers everything, list the NV4097 methods the title
  writes (RSX_MHIST) and look for ones the parser ignores before suspecting the shaders.
* Never read guest memory from the RSX/replay thread at addresses the guest did not ask the RSX to read
  (v35: sampling every ENABLED vertex attribute, incl. unused ones with stale offsets, wedged the RSX FIFO on the
  world load, 2/2 runs). For diagnostics read the converted upload buffer instead.

### 5.18 Alpha test (v36) -- check that every fixed-function state actually reaches the shader
* NV40 alpha test (ALPHA_FUNC/REF/ENABLE) has no D3D12 equivalent: it must become `discard` in the pixel
  shader. inFamous runs a whole-world pass whose program writes only rgb (alpha stays 0) with alpha test
  GREATER 0 -- on hardware every fragment dies; without the test it painted flat "buildings" over the lit
  frame. The backend uploaded the alpha params to b1 for months while no shader ever read them.
* When a pass looks like it should be invisible, list the fixed-function state at that draw (alpha test,
  colour target NONE, colour mask, depth bounds, stencil) and check each one is honoured end to end
  (parse -> record -> PSO key -> shader/PSO), not just parsed. `[RSX-UNK]` lists methods nobody parses.

### 5.19 Colour target NONE and the methods nobody parses (v36/v37)
* SET_SURFACE_COLOR_TARGET (0x0218) = 0 is CELL_GCM_SURFACE_TARGET_NONE: depth/stencil-only pass. A backend
  that maps "anything not B / not MRT" to surface A paints such a pass's colour into the last surface A
  (inFamous suspect: a world-wide depth pass landing in the light buffer). Record the target per draw and force
  the colour write mask to 0 for NONE (CT_NONE=0 disables).
* v36 also proved the opposite trap: the alpha test WAS missing (fixed, 5.18) but that pass had it disabled
  (`at=400`). Always read the per-draw state in the capture manifest (`at=`, `ct=`, `cull=`, `bk=`, `cmask=`)
  before deciding which missing feature hides a pass.
* `[RSX-UNK]` in inFamous (first run): COLOR_MASK_MRT 0x0370, BLEND_ENABLE_MRT 0x036C, ZMIN_MAX_CONTROL 0x1D78,
  ANTI_ALIASING_CONTROL 0x1D7C, SHADER_WINDOW 0x1D88, TEXTURE_CONTROL2 0x0B00+, TEX_COORD_CONTROL 0x0B40+,
  vertex data base offset/index 0x1710/0x1714, context-DMA handles 0x018C-0x01B8 (0xFEEDxxxx), plus 0x1804,
  0x1EA8/0x1EAC/0x1EF8, 0x1450, 0x173C, 0x1718, 0x1E60, 0x02B8, 0x0110. MRT colour masks / MRT blend enables are
  real rendering state and should be honoured next.

### 5.20 FACING (FP input 0xE) -- two-sided normals (v47)
* RSX fragment inputs: 0 WPOS, 1 COL0, 2 COL1, 3 FOGC, 4-13 TEX0-9, 14 = FACING (+1 front / -1 back). Map it to
  SV_IsFrontFace. inFamous' character shaders multiply the interpolated normal by FACING before NRM; with
  FACING = 0 every character's normal was NaN (black) or garbage (flicker).
* SV_IsFrontFace follows FrontCounterClockwise, so the PSO must carry the guest's front-face winding even for
  draws with culling disabled (two-sided materials are exactly those).
* Debug method that found it: decode the FP instruction words by hand (opcode bits 24-29 of the halfword-swapped
  word 0, src register type = bits 0-1 of each source, INPUT index = OPDEST bits 13-16) instead of trusting the
  decompiler's text -- an "x * 0" in decompiled code is a red flag for an unhandled input/constant.

## 7. Performance work: measure, then fix
### 7.1 Where the time goes (read these lines)
* `[PERF] F fps | tex | vtx (verts) | render_frame | prepass [srv | pso calls MISS hashed] | guest` -- every
  20 frames. `guest` = everything outside render_frame (game code on PPU/SPU + the draw recording, which
  includes the CPU vertex conversion `vtx`).
* `[SLOWFRAME] ms: GPU wait / render_frame CPU / rest (guest+recording); draws, vertex chunks, pipeline
  compiles, VS compiles, cache fill, SRV writes/skips` -- every frame over 1 s (first 40).
* `[frame-draws] flip N at T ms: D draws, V verts (max in last 50; tri-list verts; packed MB)` and
  `[world] FIRST BIG FRAME` (first frame with >= 500 batches = "the world is up") with `FRAME_DRAWS=1`.
* SPU side: `SPU_MISS_STATS=1` (interpreter fallbacks), `SPURS_STATS=1` (per workload), `[spu-speed]`.
* Linux sampling: `gdb -p <pid> -batch -ex "thread apply all bt 12"` a few times (find the pid with
  `pgrep -x`, not `pgrep -f` -- that matches your own shell). There is no `perf` in the container.

### 7.2 inFamous timeline of the frame budget (Windows, RTX 4060, title screen with the city)
| State | fps | Notes |
|---|---|---|
| Before job-module re-lift | ~1.6 | SPU jobs in the interpreter |
| After re-lift, renderer capped at 2048 draws | ~5 | but black: last 3769 draws dropped |
| All draws, small caches | 0.1-0.2 | 11 s frames, pipeline thrash |
| Big caches | 4.4 | first picture: title screen |
| Address-keyed pipelines after Start | 0.5 | endless compiles |
| Content-keyed + memo + disk cache | 4.6 | render_frame 62 -> 16 ms; black title (5.7) -> fixed in v11 |
* Steady state at ~4.5 fps (220 ms): game code ~110 ms, CPU vertex conversion ~58 ms, renderer ~16 ms.
  The game-code share is the ceiling: 30 fps needs ~33 ms total.

### 7.3 What to try next for speed (ordered by expected value)
1. CPU vertex conversion: specialise `rsx_fetch_attrib` per attribute format, convert only the slots the VP
   reads (partly done by packing), cache converted vertex buffers across frames when the guest data is
   unchanged (hash or write-watch), use index buffers instead of expanding indices.
2. Game code: the parallel SPURS kernel (3.3) once the deadlock is understood; then profile the PPU main
   thread on Windows (a sampling profiler on the user's PC beats the 2-core VM, whose numbers mislead).
3. Renderer: make SRV dedupe effective (5.8), multi-thread the prepass/command recording.

### 7.4 Texture creation is a frame-time cliff (inFamous, 2026-10-05)
* A long black screen / multi-second hitch at a scene change with `texup N new (create X s)` large in PERF is
  resource CREATION, not rendering: CreateCommittedResource cost ~3.5 ms each on an RTX 4060 once hundreds of
  textures are live (kernel allocation + residency). Fix pattern: placed resources sub-allocated from big DEFAULT
  heaps (ALLOW_ONLY_NON_RT_DS_TEXTURES; free a range only after the GPU is idle), ONE ring UPLOAD buffer for all
  staging instead of one per texture, and an LRU texture cache large enough for a scene (inFamous city: > 1024
  distinct textures across a cutscene). A "first slot not used this frame" victim rule thrashes.
* Lock contention in the SPU runtime shows up as the HOST symbol `spu_lockline_lock` at the top of a Windows sample
  (resolve rvas with build-fast\inFamousRecomp.map). Stripe the lock-line lock by line address; keep an all-stripes
  path for multi-line ops; never take a stripe and then the all-stripes lock on the same thread.

### 7.5 Per-pass capture beats guessing (inFamous, 2026-10-05)
* Snapshot every colour target when the replay LEAVES it (target switch / end of frame) into one big readback
  buffer; write raw RGBA + a pass list. One frame then shows exactly which pass first goes wrong.
* Never compile fragment programs from guest memory at flip time: games write generated FPs into a RING and reuse
  slots within a frame. Snapshot the ucode per draw at record time (dedupe by addr+hash).
* Emulate stencil early: deferred renderers tag materials in the G-buffer stencil and mask later passes with it;
  without it those passes cover the whole screen (flat colours, "ghost" geometry).
* Off-load vertex conversion to workers, but drain before anything the guest can observe (labels, semaphores,
  reference, 2D transfers) and before the GPU reads the buffer.

---

### 7.x RSX-thread costs that scale with draws/indices (v46)
* Index dedup by hash table costs ~5-10 ns per index; a city frame has ~2.6M indices. Most index lists cover a
  compact [min,max] range: convert the range (on worker threads) and rebase the indices -- one min/max pass.
  Keep the hash for sparse lists (span > count).
* Per-draw descriptor tables: consecutive draws (shadow casters, same-material runs) usually bind the identical
  texture set. Re-bind the previous draw's table when the unit state is byte-identical and nothing in it is a
  per-draw-resolved source (render target alias, depth copy, shadow zeta).
* Per-draw constant buffers: never copy the whole 8 KB VS constant bank per draw; copy the constants the VS
  actually reads (static mask from the decompiled source; relative addressing -> copy all).
* NRM/normalize of a zero vector must be 0 (RSX multiplier rule), not NaN; a NaN output guard turns it into
  black G-buffer normals (characters rendered black).

### 7.6 From 15 to 25 fps in one evening (inFamous v59-v70, 2026-10-06) -- method and lessons
**Method that worked (do this first next time):**
* Cheap always-on telemetry beats ad-hoc profiling runs. Three probes paid for themselves:
  - `[TELEM]` per guest thread: time inside each lv2 syscall + the guest `lr` of the biggest one (two QPC reads
    per syscall). Tells WHO waits WHERE ("main thread 40% in sc141 usleep at lr 002D0054 = a WWS job wait").
  - `[TELEM-CPU]` per HOST thread: CPU% + start RVA (resolve with the map: frame_clock = FIFO thread,
    spurs_kernel_thread, spurs_lane_worker, rf_thread_main, va_thread, mainCRTStartup = main guest thread).
  - `PS3_PROF_MAIN=1`: a TIME_CRITICAL thread that suspends ONLY the threads of interest (main, FIFO, SPURS) every
    1-2 ms via kept handles (no Toolhelp snapshots: the old all-thread sampler got ~20 samples/report), records
    exe RVA of RIP (+ the first exe return address; for samples parked in a syscall stub, unwind with
    RtlVirtualUnwind). Lifted guest functions are `func_XXXXXXXX` symbols in the exe, so the map resolves them.
* In-run A/B (`PS3_AB=1`): rotate a global knob mask every 12 s and tag the `[PERF]` lines with the phase. One
  3-minute play session compares 4-5 variants under the same scenes -- far better than build-per-variant.
  Compare per cycle (adjacent phases), the scene noise is +-3 fps.
* Hitch probe: keep a ring of the last few thousand main-thread samples with timestamps; any frame > 250 ms dumps
  what the main thread did inside that frame (`[HITCH]`).
* Verify fast paths differentially on Linux: run the old and new code on a shadow state and memcmp
  (`GCM_TC_CHECK`). It caught a wrong range (0x1FC0/0x1FF0 are not transform constants) before the user saw it.

**What moved the needle (in order of effect):**
1. Converted-vertex cache in VRAM (v60, `VCACHE`): 86-98% of the city's ~2M vertices/frame are byte-identical
   frame to frame. Key = fetch plan + index range + 64-bit hash of the raw guest bytes; misses convert into the
   upload chunk + GPU copy into a DEFAULT buffer at the start of the frame's command list; absolute u32 indices so
   batches still merge. Pitfalls hit: a stream that starts cached and continues uncached (IO page crossing) splits
   256-index batches out of phase = holes in skinned characters -> hash IO-page-crossing ranges piecewise, and let a
   batch that continues an uncached stream stay uncached.
2. SPURS kernel idle policy (v67/v68): 9 kernel threads spinning (SwitchToThread) 30 ms after the last work stole
   cores/SMT siblings from the real work. 30 ms -> 0.5 ms spin, then 250 us high-res timer waits: +15-20%.
3. Off-thread D3D12 replay (v59 RF_ASYNC) + per-draw FIFO-thread cuts (v64 VP rehash only when the microcode
   changes, FP memo; v65 direct store of vertex-constant uploads = 57% of all methods) took the FIFO thread from
   ~80% to ~45% busy -- necessary, but FPS only moved once the SPU idle policy changed.
**What did NOT help (do not repeat without a new reason):** pinning the main thread to P-cores / HIGHEST priority;
PAUSE-spinning short usleeps; disabling the SPU identical-poll backoff; packed-SSE SPU float ops (SPU threads were
idle anyway); the GoW2 port reports the same for SPURS worker counts and big-core affinity.
**Presenting the right buffer:** never take the display buffer from the PPU's latest flip REQUEST (the main thread
runs ahead): drop a marker into the flip's command context and present what the FIFO actually reached (v62), and
only if that buffer was drawn this frame (v62b), else the game's prompt/HUD vanish or the screen goes black.
**Reference port:** andrebrumdev/gow2-recomp (GoW2, 45-60 fps on Apple M5) -- its README lists measured A/Bs:
32 KB command-buffer fragments removed PPU overflow waits; devirtualising the hottest indirect calls -13% CPU/frame;
a dedicated RSX thread helped on Vulkan.


**v82/v83 follow-up (2026-10-07): find the waiter's real wait loop before optimising the wake path.** Once the GPU
side is cheap (inFamous play80: render CPU 5-7 ms, GPU wait < 1 ms at 25 fps) the frame is the guest CPU plus its
hand-offs. v82 woke parked SPURS kernels on every guest short usleep -- and lost ~1 fps in the A/B: the dominant wait
never calls usleep. A main-thread-only profile (PS3_PROF_MAIN_ONLY) showed 40% of samples in one tiny lifted function
(func_0041D028: "min of the per-SPU progress cursors >= n") called in a bare spin loop (func_0041FC38). Lessons:
(1) aggregate the profile by *lifted function*, not by host DLL -- a guest spin loop is 100% "in the exe" and looks
like work; (2) a progress-cursor wait needs EVERY emulated SPU to run a pass after the job is queued, which hardware
gives for free (SPUs poll continuously) and a nap-based scheduler does not; (3) hook the exact guest wait (hand patch
of the generated function, begin/spin/end callbacks) so the runtime knows when latency matters, and keep the boost
scoped to that window and to the owning kernel thread; (4) always ship such changes behind an in-run A/B with a
per-phase fps line, because "obviously faster" wake-ups can lose (v82).
**Result (play83): the boost did not help either** -- instrumenting the hooked wait ([TASKWAIT]: count, wall ms, mean,
max) showed ~12 waits/frame of ~0.5 ms each that stayed the same with the scheduler kept awake: the latency is the
emulated SPU work itself. Takeaways: (5) measure the wait in wall time at the hook -- a 1 ms sampler over-counts a spin
loop; (6) prove the latency is "discovery" (fast with a hot spinner) before building wake-up machinery -- a single A/B
phase with an always-spinning owner thread answers that in one run; (7) the next lever is the SPU job path the
waiter depends on (lane profile during the wait), not the scheduler.

### 7.7 22 fps: the SPU job lists the main thread waits on (inFamous v85-v93, 2026-10-07)
* Find WHAT the main thread waits on before tuning wake-ups. inFamous' CTaskMgr wait (func_0041FC38 / lr 0x41FC70)
  polled 0x7DF000 = the m_joblistMesh workload data. That one workload did ~30 ms of serial SPU work per frame.
* Running m_joblistMesh (w1) and BatchJobList (w2) with concurrent lanes (SPURS_PAR_LANES, the same WWS PM as the
  CTaskMgr lists) took the city from ~14 to ~22 fps with no hangs. An older parallel design deadlocked on the same
  list; the difference is that PAR_LANES keeps every lane on fixed threads.
* Measured non-wins (keep the switches, default off): fence publication pacing (99% of ref polls found nothing
  queued, so the FIFO walker just had no commands yet); one dedicated thread per heavy workload; full lane sweeps
  during the wait (lane-cursor lag was not the cost).
* Once the main thread is ~95% busy (guest code + task wait) and the waits are genuine SPU work, settings are
  exhausted: speed up the lifted SPU code (register caching in the lifter, runtime MFC/channel overhead).


**Lessons from v94/v95: making the lifted SPU code itself faster.** The lifter's
`ctx->gpr[N] = op(ctx->gpr[A], ...)` form sends every operand through memory, and every LS
store (`uint8_t*`) can alias `ctx->gpr`, so the compiler reloads everything after each store.
Keeping SPU registers in per-function locals only pays off with all three of the following:
(1) **Look at the object code, not the source.** Clang's SROA split the `u128` union locals into i64 halves
because the scalar helpers write lanes through `_u32[]` and `_u64[]` views. The "optimised" object came
out 1.3-1.7x larger, with hundreds of stack spills per function, on both the SysV and the Win64 target
(cross-compile with `--target=x86_64-pc-windows-msvc` and stub libc headers to check).
Whole-register `__m128i` helpers (`spu_helpers_vec.h`) fixed it.
(2) **Remove the always-on debug probes from the hot accessors.** Watchpoints and low-read/SMC probes cost
3 global loads and branches per LS access and half the code size; in the rc copy the runtime gates them
instead.
(3) **Keep the original as a run-time twin.** Generate the transformed copy under new symbol names and
let the function registry hand out either copy (`SPU_REGCACHE=0/1/ab`). The two copies are
interchangeable at every runtime boundary, so this gives a safe fallback and an in-run A/B from one build.
Validate with a differential harness, not by playing. Run every lifted function from identical random
ctx + LS through both copies, hash ctx + LS at every runtime call and at exit, and have the stubs clobber
registers at calls so that a missing reload shows up. Then plant a bug to check that the harness catches it.
The harness found a real v94 bug: a line `x; if (c) { ...; return; }` was classified as an unconditional
return, so the register reload after it was skipped. It also showed the warm speed-up (1.5x over all
functions) before the build ever ran on the target.


**v95/v96 (2026-10-07): a faster job body does not shorten a pass-bound wait.** v95 made the lifted SPU code 1.5-1.9x
faster (bit-exact, differential-tested) and the PPU's CTaskMgr wait did not move: per-lane busy-run time stayed ~190 us
across versions, i.e. >80% of a lane run is runtime (dispatch, wake/join, reservations), and long waits are ~25 kernel
passes each paying two OS wake-ups. Measure the composition of the wait ([LANEPROF]) BEFORE optimising compute. When
splitting work across parallel agents, give each a disjoint file set and its own build tree, and reserve one A/B phase
per agent (g_ab_mask phase index) so one user run attributes the gain.


**v97 (2026-10-07): tag every PPU wait with the workload it waits on ([TWCUR]) before choosing what to parallelise.** We
assumed the CTaskMgr wait was on w1/w3; tagging showed w5/w6 (menus) and w8/w9 sharing kernel threads with w1/w2. Two
cheap structural fixes followed: a lane that found work re-runs its policy module at once instead of waiting for the
slowest lane's pass (hardware SPUs do this), and busy CTaskMgr lists get their own kernel thread (with a per-workload
lock so a workload never runs on two threads). Also: a "stall breaker" that resets idle workloads must check for real
PPU-visible stalls; restarting on plain idleness is noise at best and lost work at worst.

## 8. Index: environment variables and log tags (renderer and friends)
* Renderer budgets/caches: `VP_VB_VERTS` (vertex chunk size), `VP_PACK=0`, `SRV_DEDUPE=0`,
  `SHADER_DISK_CACHE=0`, `FP_CONSTBUF=0` (literal FP constants), `FP_KEY_ADDR=1` (address in the pipeline key).
* Renderer diagnostics: `FRAME_DRAWS=1`, `GCM_FLIPCOUNT=1`, `FRAME_BUDGET=1`, `D3D12_DRED=1`, `D3D12_DBG=1`,
  `CELLMARK_DUMP=3` + `CELLMARK_DUMP_MINDRAWS`, `RTT_SAVERT=<hex>[_AFTER]`, `RT_OFFDBG=1`, `RT_CLEARDBG=2`,
  `DEPTH_OFF`, `CULL_OFF`, `CMASK_FORCE`, `VP_ATTRS[_FP|_DUMP]`, `VPC_DUMP_FP=<hex>`, `PSOMISSDBG=1`,
  `HASHDBG=1`, `CUBEKEYDBG=1`, `FP_LIST=1`, `FP_DUMP=1`, `FP_PICK=<hex>`, `FPK_DBG=1`, `VP_SUBMIT=<n>`,
  `DRAWARGS=<n>`, `TEX_BINDDBG=<n>`, `SCREEN_AS_TEX=0`.
* v33/v34 renderer switches: `FP_SNAPSHOT=0`, `GUEST_STENCIL=0`, `VTX_ASYNC=<n>`, `ZFLAT=0`, `GUEST_DEPTH_RANGE=1`,
  `SHADOWS=0`, `SHADOW_FLIP=1`, `SHADOW_LIT=0`, `SHADOW_SKIP=0`, `CAP_AUTO=<s,..>` (+F9), `STENCIL_LOG=<n>`
  (`STENCIL_FP`, `STENCIL_SURF`), `CLEAR_LOG=<skip>`, `DEPTH_BOUNDS=0`, `ALPHA_TEST=0`, `CT_NONE=0`, `VIB_RANGE=0`, `SRV_ALIAS=0`, `VCB_PARTIAL=0`, `FP_NRM_ZERO=0`, `FP_FACE=0`, `FP_FACE_FLIP=1`; tags `[ZFLAT]`, `[DBT]`, `[RSX] depth bounds`, `[ATEST]`, `[RSX-UNK]`, `[CT]`, `[RSX] depth range`, `[SHADOW]`, `[STENCIL]`, `[CLR]`.
* Log tags: `[VPVB]`, `[VPCB]`, `[VPPACK]`, `[FPBUF]`, `[SLOWFRAME]`, `[VIDMEM]`, `[CACHES]`, `[PSOCACHE]`,
  `[VSCACHE]`, `[SHADERCACHE]`, `[PERF]`, `[frame-draws]`, `[world] FIRST BIG FRAME`, `[DRED]`,
  `[SCREENTEX]`, `[CUBE]`, `[cellPad]`.
* SPU/SPURS: `SPU_MISS_STATS=1`, `SPURS_STATS=1`, `SPURS_PAR_SPUS=1` (deadlocks, see 3.3), `RD_SPU_INTERP`,
  `WWS_RUNWATCH`, `JOBMOD_EXTRA_MAP=<json>` (lifter).
* Input: `PAD_NO_THREAD`, `PAD_NO_KEYBOARD`, `PAD_AUTOPRESS`, `PAD_SCRIPT`, `PAD_ALWAYS_CHANGE`.
* Texture transforms: `TEX_XF=0` (v89). MRT state: `MRT_MASKS=0` (v90). Shadows: `SHADOW_FLIP=1` (old order), `SHADOW_BIAS=<f>` (0.0015). SPURS: `TASKWAIT_SWEEP=0` (v92), `TASKWAIT_BOOST=1`, `GCM_REF_GAP_US`, `RSX_IDLE_MS`.
* SPU floats: `SPU_XFLOAT=0` (v52, raw x86 Inf/NaN). Capture: `CAP_VDUMP=<srefs>` (v51 character vertex dumps).
* FIFO sync: `GCM_SEMA_ACQUIRE=0` (v50, never wait), `GCM_SEMA_TIMEOUT=<ms>` (50).
* Depth copy: `ZCONV_STALE=1` (v49, old never-refreshed copy).
* Port (inFamous): `INFAMOUS_HANGDUMP=<s,s,...>`, `INFAMOUS_BINK_COMPLETION`, `LWM_TRACE_EA`.

---

## 9. Per-title checklist (first day and beyond)
- [ ] Decrypted EBOOT.elf, PARAM.SFO and disc layout present. Set `PS3_VFS_ROOT` if the layout is unusual.
- [ ] Lift the PPU (`tools/ppu_lifter.py`).
- [ ] Extract and lift the SPU images (`spu-images/`, `spu/`, `build_spu_workloads.py`).
- [ ] Windows build with `build.cmd`. Also build on Linux in the cloud for a fast debug loop.
- [ ] First run: collect `[fs] open` (data needed), `sys_ppu_thread_create` (thread names), `[SPU] group_start` (which SPU images run lifted vs interpreted).
- [ ] Note any title patches in `stubs.cpp` and document **why** each exists. Patches that paper over races (like inFamous' movie texture pool retry) are prime suspects later.
- [ ] Keep `HANDOFF.md` current at the end of every session.
- [ ] POSIX VM is a 4 GB-aligned mmap (fact 34) and sys_fs root == cellFs root (fact 38) before the first Linux run.
- [ ] Before the first 3D frame: raise every renderer cap/cache to real-game sizes (chapter 5.2) and turn on
      FRAME_DRAWS=1 so the first big frame reports its real demand.
- [ ] As soon as the world loads: SPU_MISS_STATS=1, fill lift gaps (3.1), then measure (7.1) before optimising.
- [ ] Input: confirm `[cellPad] host poll thread started` and that presses reach the game (6.1).

### FPS work (added 2026-10-04 evening)
* **Know what each PERF bucket contains before optimising it.** In this renderer `guest` is "not
  render_frame", so it silently includes CPU vertex conversion and every wait on SPU jobs.
* **Convert each vertex once per draw.** Indexed meshes and strips reference a vertex 2-6x; an RSX
  backend that converts per reference (resolve + format decode per attribute) burns most of its vertex
  time on duplicates. Memoize by index in a CPU-side cache, and never read back from a write-combined
  upload heap (reads there are uncached and catastrophically slow).
* **Turn the D3D12 debug layer / DRED off for speed measurements.** They are right for black-screen
  hunts and wrong for FPS numbers.
* **Link with /MAP** so the sampling profiler's host RVAs can be named; a profiler that can only say
  "inFamousRecomp.exe 60%" is not actionable.
* **Parallelise SPURS by WORKLOAD before parallelising by lane.** One host thread running every
  workload of a 5-SPU instance makes the PPU wait on SPU throughput every frame. Giving each kernel
  thread a fixed set of workloads keeps each workload's lane order and ownership exactly as before
  (no claim races) while different workloads overlap like on hardware. Letting any thread claim any
  (workload, lane) is the riskier step -- it deadlocked here.
* **Per-run counters read after a run must be thread-local** once more than one kernel thread exists.
* **Don't sleep between passes that found work.** A dependent task chain advances one step per pass;
  a 1 ms sleep per step lands directly on the PPU's frame time.
* **Profile per THREAD with names before touching anything.** PS3_SAMPLE + samp_full.txt + the link map
  (`_xfer/samp_agg.py` in the inFamous tree) showed in one run that the renderer was half idle, the PPU
  was only waiting, and the SPU threads spent most of their time in runtime bookkeeping -- three guesses
  in a row had pointed elsewhere.
* **An SPU spin-poll that is free on hardware costs a host core + a global lock here.** Look for
  `[spu-spin] ... x4M` and back off on long runs of byte-identical GETLLARs.
* **No shared writable statics on per-instruction/per-branch paths.** A diagnostic ring written by every
  SPU thread is a cache line bouncing between all cores on every step.
* **Faster decode does not help a write-bandwidth-bound upload.** If PERF vtx does not move after making
  conversion cheaper, count bytes written (verts x stride) -- the fix is uploading less (index buffers,
  only the inputs the shader reads).
* **A host thread that is idle while the PPU waits on it means latency, not throughput.** Sleep(1)
  between scheduler passes costs >= 1 ms per dependency hop; spin with yields for a few ms after the
  last real work before sleeping.
* **Set PS3_VERBOSE=0 for any timing run.** Redirected stderr turns verbose logging on by default, and
  per-event lines from audio/driver threads serialize every guest thread on the CRT file lock.
* **After spreading SPU work over threads, re-check for interpreter time.** One lift gap that was noise
  on a serial kernel became the critical path once the other workloads ran in parallel (inFamous: one
  mid-function target, 0.4 ms per call). SPU_MISS_STATS=1 + JOBMOD_EXTRA_MAP + re-lift ONLY the changed
  modules (temp --jobmods dir), then verify the new function set is a superset of the shipped one.
* **Compile lifted SPU code for the host CPU's FMA.** fmaf() without -mfma is a libm call per lane.
* **Present the buffer the guest FLIPPED, not the one your frame splitter last drew to.** With display
  buffers rendered as offscreen targets, titles that ping-pong two display buffers and draw their UI last
  (or at the start of your recorded frame) lose the UI and look 'frozen'. Dump every display buffer in
  a capture: the correct image is usually sitting in the other one.
* **New workloads mid-game can overflow per-context tables that were fine at boot.** inFamous adds CTaskMgr
  workloads at the cutscene; persistent PM contexts (wid x lanes) crossed 64 and the shared fallback MFC
  engine froze the game. Grep every run for 'more than %d' warnings, and size per-context tables for
  max workloads x lanes, not for what the title shows in the first minute.
* **Profile DLL time by name** (dbghelp SymFromAddr on samples outside the exe): it separated real sleep
  (NtDelayExecution) from hidden costs (ucrtbase!strchr = uncached getenv; SRW lock churn).
* **Parallelise vertex conversion per draw, synchronously.** When the RSX replay thread is the limiter and
  most of it is guest-vertex fetch/convert, split each large draw's output list across a small worker pool
  (private fetch-plan copy + private memo per worker) and WAIT for it before the next FIFO command. No new
  ordering hazards (semaphores, labels, guest rewrites of vertex memory) -- unlike deferring the work.
  Test the splitter off-target with a pthread harness against the serial path (bit-identical output).
* **Honour the guest's sampler state.** Static samplers in a root signature are easy to write once and
  forget: inFamous' unit 0 was point/clamp (a debug-font leftover), so every diffuse map looked blocky.
  Build sampler tables from TEXTURE_FILTER (min bits 16-23: 1 nearest, 2 linear, 3-6 mip variants, 7 conv;
  mag bits 24-27) and TEXTURE_ADDRESS (wrap S bits 0-3, T 8-11, R 16-19: 1 wrap, 2 mirror, 3 clamp-to-edge,
  4 border, 5 clamp, 6-8 mirror-once), cache them by key and never evict (no in-flight hazards).
* **A texture format your backend skips must not leave the unit holding the previous texture.** Log
  unsupported formats once each; a stale binding looks like "random wrong textures" on some surfaces.
* **Check draw sizes before parallelising per draw.** inFamous issues ~10k draws/frame of ~230 vertices; a
  per-draw worker split never triggered (PERF `0k mt`). Print the share of vertices that would qualify first.
* **When no thread is saturated, you are latency-bound: hunt the sleeps.** Resolve "blocked" samples by DLL
  symbol: NtDelayExecution = Sleep(), and every Sleep(1)/Sleep(4) on a producer->consumer hop (RSX drain loop,
  lwcond poll, idle SPU kernel threads) is paid per hop, several times per frame. Replace them with waits on
  an event/condvar that the producer signals (keep the old timeout as a cap so poll-dependent code still works).
* **Keep diagnostic hooks off the guest memory hot path.** Lifted code calls vm_read*/vm_write* for every
  load/store (stack included). Ten lazily-initialised getenv'd hooks per access cost the inFamous main thread
  ~70% of its busy time. Gate them all behind ONE flag computed once (any diagnostic env set -> slow path).
* **Depth-format textures are shadow-map lookups** (RSX does the compare in the texture unit: TEXTURE_ADDRESS
  zfunc bits 28-31). Until the compare is emulated, bind a "lit" stand-in (component mapping FORCE_VALUE_1),
  never a stale binding.
* **Never put a `*/` sequence in a C comment** (e.g. "vm_read*/vm_write*"): it ends the comment and the
  build fails in a confusing place. Write "vm_read / vm_write".
* **Instrument per-workload SPU time before optimising the SPU side.** With workloads partitioned over host
  threads, one thread at ~90% while the rest idle means a single workload (or an unlucky wid % N mapping) is
  the frame's critical path; a per-wid ms/% report every few seconds names it.
* **Latency fixes beat throughput fixes when nothing is saturated.** inFamous went ~4 -> 7-11 fps in-game
  and ~8 -> 32 fps on the title purely from replacing Sleep()-based waits with signalled waits and taking
  debug hooks off the memory path -- no rendering or SPU code got faster.
* **Count "runs that found work" per workload.** A SPURS workload with thousands of runs but ~0 busy runs
  can still dominate a kernel thread if each idle run spins inside its quantum; that is wasted critical-path time.
  **But check the counter first:** with sequential lanes (SEQ_LANES) a per-run counter that is reset per LANE
  only describes the last lane -- inFamous' main CTaskMgr looked "idle" for exactly that reason. Sum over lanes.
* **Per-instance state in profilers.** A report timer shared by two SPURS instances let one instance starve the
  other's report, so its "10 s" sums covered minutes (percentages > 100%). Any windowed stat keyed by
  instance needs its window keyed by instance too.
* **Give the heaviest workload its own kernel thread** (SPURS_WKL_SOLO / SPURS_WKL_MAP) instead of a blind
  wid % n partition -- the main task manager otherwise queues other systems' work behind it.
* **Count the draws by pass before optimising the renderer.** One rsxcap manifest showed 69% of inFamous'
  draws were colour-masked shadow-map passes whose result we were not even sampling (shadow lookups forced
  lit). Skipping invisible work beats speeding it up. Key the skip on the surface's observed USE (sampled
  only as a depth-format texture, never as colour) rather than on hard-coded offsets.
* **Never expand indexed geometry into flat triangle lists on the CPU.** Convert each unique vertex once and
  upload an index buffer (DrawIndexedInstanced); in a city scene that halves vertex writes (4.3M output vs
  2M unique vertices per frame) and lets the GPU's post-transform cache work. Keep the begin/end batch
  concatenation (out-of-phase index batches) by adding the merged record's vertex count as index bias.
* **Present(1) on the replay thread is a hidden frame-rate cap** when that thread is the limiter: it blocks
  until vblank every frame. Use sync interval 0 with flip-model windowed swap chains.
* **SPU helper semantics as byte loops are a silent 10-15x tax.** Quadword rotates/shifts (rotqby,
  shlqbyi, rotqmby...) and the cbd/chd/cwd/cdd insertion masks run on nearly every scalar load/store in
  lifted SPU code; implement them as one pshufb with a precomputed 16x16 control table, verified
  exhaustively against the scalar reference.
* **Inline the guest load fast path into lifted PPU code** (bounds + MMIO-window check + bswap load);
  out-of-line vm_read* calls were half of the main thread's busy time.
* **Ship a profiler that names lifted SPU functions with their module** (exe RVA -> jobmod_<hash>_spu_func)
  and a per-workload spin counter: "busy" vs "waiting" decides whether to optimise code or scheduling.
* **Measure the scene that is slow, not the one that is easy to reach.** Title/menu went to 32 fps while the
  first cutscene stayed at 3-6; a profiler that reports every 10 s missed the short cutscene entirely. Keep
  report windows short (5 s) and capture (F9 rsxcap) IN the problem scene.
* **One global atomic lock does not scale with host threads.** The lock-line spinlock that serialises
  GETLLAR/PUTLLC/coherent PPU stores was invisible with 1-2 SPU threads and costs 6-9% of every SPU thread
  with ~50; plan per-line lock striping before adding more parallel SPU workers.

### Idle polling vs. parallel lanes (inFamous v31)
If idle workloads are polled one lane per pass (to save CPU) AND busy workloads run their lanes in
parallel, the lane that DISCOVERS new work drains the whole batch alone -- the parallel sweep only runs on
the next pass and finds nothing. Symptom: [pm-time] shows long max runs (100+ ms) while the parallel lanes
sit at ~1%. Fix: hook the policy module's first selectWorkload poll (= "found work") and wake the other
lanes from inside that run. Measure busy runs per path, not just per workload.

### PUTLLC must not memcpy the whole line (inFamous v31e)
Emulating PUTLLC as "memcmp(line, reserved copy) then memcpy 128 bytes" under an SPU-only lock loses any
PPU store/stwcx. that lands between the two (a PPU thread preempted between its "is this line reserved?"
check and its CAS is enough). Symptom: a WWS job list stuck on a dependency-wait command whose counter
never reaches 0. Commit only the words the SPU changed, each by CAS from the reserved value; fail the
PUTLLC if one of them moved.

### Every guest-memory writer must go through the coherence layer (inFamous v31i/j)
SPU atomics (GETLLAR/PUTLLC) only stay correct if EVERY other writer to guest memory takes the lock-line lock
when the line is reserved and notifies reservations. Easy to miss: lifted PPU vector stores (stvx emitted as a
raw memcpy -- 44k sites), dcbz (raw memset), HLE libc memcpy/memset, HLE library memcpys, raw-SPU DMA.
Debug recipe that worked: a ring buffer of every write to the suspect words (filter by value pattern), tagged
with writer kind + PPU lr / SPU pc, printed from the hang dump; check that each event's old value equals the
previous event's new value -- a gap is an untraced writer, a rise mid-batch is a stale-copy overwrite.
* **Handle every RSX vertex type, especially 6 = CMP** (one big-endian dword, signed-normalized x:11 y:11 z:10).
  Games pack normals/tangents with it; read as float32 it gives saturated/garbage G-buffer normals and unlit
  black silhouettes while the albedo looks perfect. Log the (attribute, type, size) combos a title uses early.
* **Watchdogs/breakers must not keep their counters in process-global statics.** A "same DMA 256 times -> halt
  the SPU" breaker summed the transfers of ALL threads; once several SPU lanes polled the same line it fired
  thousands of times and killed lanes mid-job (lost jobs, missing objects, freezes). Per thread/context, and
  never for a module that polls by design.
* **Check the game's import list before hooking an HLE function** (grep the NID in the lifted code): a whole
  test cycle was spent hooking _sys_memcpy, which inFamous never calls.
* **A headless cloud build of the port (null renderer, 2 cores) reproduced a multi-thread freeze** and lets
  you iterate without the user; add an input autopress and a hang dump keyed on the stuck guest lr.
* **When tracing writes to a word, trace 8/16-bit stores too** -- a counter living in a halfword is invisible
  to a 32-bit-only trace and looks like an "untraced writer".
* **Non-atomic guest read-modify-writes that are "safe enough" on hardware are not safe recompiled.**
  inFamous bumps a job-dependency counter with lhzx/addi/sthx while SPUs decrement it with GETLLAR/PUTLLC;
  on a real PPU the window is a few cycles, in recompiled code (out-of-line accessors, tracing, host
  preemption) it is wide enough to lose a decrement every few minutes -> permanent wait. Find the site with
  a write trace (writer kind + guest lr, 8/16-bit stores included), then make that one sequence atomic
  under the same lock the SPU atomics use (inFamous: ppu_atomic_add16 + tools/patch_atomic16.py).
* **Before blaming your SPU parallelism, test the serial configuration under the same repro.** The freeze
  looked like a "too much concurrency" bug (it got worse with more lanes) but reproduced fully serial too.

---

## 10. Second title: Tokyo Jungle (BCAS20233), 2026-10-07/08 -- what generalised

Starting point: the title booted, played four flips and shut itself down ("sgxbus.c: unknown module name
(tverb)"). End of this session: logos, title screen, menus, and Survival can be selected on the user's
Windows PC. Every fix below is in the shared toolkit unless marked (port).

### 10.1 What the playbook bought, honestly
* Chapter 1 (Linux fast loop) paid for itself many times: one session ran ~30 headless runs in the cloud
  container; the user ran one Windows build. Without it, each of the six blockers below is a round trip.
* Facts 2.1/2.2 (POSIX VM) predicted the very first Linux failure exactly (item 34).
* 1.2.6 (CRLF) and fact 20 (stale commits) both bit again even though they were written down -- read them
  as a checklist before every push, not as background.
* What it did NOT cover: SGX (Sony's sound library) and job-chain semantics -- every root cause in 10.2
  was new. The method (instrument the guest's own data structure, read the lifted code around the
  failing check, decide from the evidence) is what carried over, not specific answers.

### 10.2 Numbered facts (continue the chapter-2 numbering)
34. **The port's main.cpp may still have the old POSIX VM.** `calloc(0xE0000000)` is unaligned; every
    `sys_memory_allocate` fails and the C++ runtime throws `bad allocation` at boot. Reserve 8 GB with
    `mmap(PROT_RW, MAP_NORESERVE)`, align to 4 GB, `ppu_vm_size = 0`. Check this on every new port.
35. **Job-chain completion is NOT an event.** Real SPURS sends nothing when a job chain finishes; jobs that
    reply do it themselves through an SPU event port (`sys_spu_thread_send_event` -> the queue attached
    with cellSpursAttachLv2EventQueue: data2 = (port<<32)|data0, data3 = data1). cellSpurs used to push a
    synthetic "chain done" event to EVERY attached queue: the PPU took it as job 0's reply (empty module
    descriptor -> "unknown format type ()"/"failed to regist module"), it overflowed the 16-deep reply
    queue (real replies dropped with EBUSY), and it went to the SPU printf server's queue too, whose
    handler then wrote a mailbox to "SPU thread <chain EA>". Now off by default (`SPURS_JC_SYNTH=1`).
    Symptom to recognise: a size-then-populate pair of guest calls returning different sizes (Windows
    284 vs Linux 276 for the same module) = a reply race, not a parser bug.
36. **JOBLIST (job-chain opcode 6) must run its jobs**: `{u32 numJobs; u32 sizeOfJob; u64 eaJobList}`.
    Tokyo Jungle's anim/geom chains are JOBLIST / SYNC / JOB / END and the trailing job sets the SPURS
    event flag the main thread waits on every frame.
37. **A new streamed job = a new lift batch.** `SPU_DUMP_MISS` captured it; wrap the raw blob as an SPU
    ELF at LS 0 (`wrap_spu_raw.py`, kept in the port's tools notes) and lift it with
    `build_spu_workloads.py --images spu/job-images-2 --image-base 212 --out spu/jobmods2_register.c`.
    The port CMake now globs `spu/jobmods*_register.c`, so batches never renumber shipped image ids.
38. **sys_fs has its own root.** `g_sys_fs_root` defaults to "." (the cwd) and only adopts
    `$PS3_VFS_ROOT`; the cellFs layer uses `ppu_vfs_root`. A title that opens assets through raw sys_fs
    (Tokyo Jungle: titleTexPack.pac, edge/, lang/) then misses everything and quietly shuts down. The port
    main.cpp now copies `ppu_vfs_root` into `g_sys_fs_root` right after deriving it.
39. **cellAudio block tags must stay consistent when the guest producer is slow.** SGX renders
    "until caught up with the read index", tags each block (GetPortBlockTag) and fires voice-end callbacks
    only once GetPortTimestamp(tag) succeeds. On a slow host the producer never caught up, never reached
    its consumer, re-tagged slots each lap (the awaited tag receded forever) and its 128-entry callback
    ring jammed ("sgxps3ps3.c(1922): couldn't append tag slot (128,127)"). The intro waits for a logo
    jingle's voice-end callback, so the game froze on a mid-fade. Two fixes: (a) a block "more than half a
    ring ahead" is a LATE block and is dated in the past (`AUDIO_TAG_LATE=0` = old); (b) tag pacing -- the
    clock-paced mixer waits (<= `AUDIO_TAG_WAIT_MS`, 40) while the title is not at least
    `AUDIO_TAG_MARGIN` (1) block ahead of the reader. `AUDIO_RATE=1` reports "tag waits".
40. **Sail's descriptor database is a CellPamfReader.** Tokyo Jungle calls
    cellPamfReaderGetPresentationStart/EndTime on the buffer it passed to cellSailDescriptorCreateDatabase
    (movie length). The stub left it empty and the HLE dereferenced NULL (crash starting Survival, read
    fault 0x18, "last HLE cellGcmGetFlipStatus" -- the last-HLE line is only the last NAMED call; resolve
    the crash RVA with the .map). CreateDatabase now reads the PAMF header from the URI and binds it;
    the Pamf getters return 0 for an unbound reader.
41. **Headless null renderer as an eye.** `NULLSW_DRAWLOG=<present #>` or `NULLSW_DRAWLOG_EVERY=<n>` logs
    every draw (attributes, first vertices, colour alpha, texture) and dumps each bound texture raw as
    `dl_tex_<ea>_<fmt>_<w>x<h>.raw`; decode DXT5 offline with Pillow (`Image.frombytes('RGBA', size,
    data, 'bcn', 3)`; fmt 0xA8 = DXT5 linear, 0xA5 = A8R8G8B8 linear). Reading the atlas plus per-quad
    UVs/alpha told us "SCE presents -> JAPAN Studio -> Crispy's -> fade stuck at 0.48" without a GPU.
42. **Name the waiter, then instrument the guest's own queue.** Both SGX bugs were found by adding
    fprintf lines straight into the lifted function (e.g. `[TJ-TAG]` in the ring append, `[TJ-C600]` in
    the consumer loop) and printing the guest struct fields -- faster than any generic tracer. Keep such
    edits out of the shipped lift (they live only in the cloud copy) or mark them clearly.

### 10.3 Session mechanics that worked (device bridge)
* Background jobs do not survive a `device_bash` call (even with setsid). Tar game data in <= 170 s
  chunks (~4-5 MB/s from the Windows disk), `split -b 250M` anything over 400 MB, stage the tars.
* `device_stage_files` accepts `~/mnt/<folder>/...` spellings -- no backslash escaping needed.
* `tar x` on the device must use `--overwrite` (plain tar unlinks first, and deletion is disabled).
* Python text-mode edits silently turn CRLF files into LF (it happened to cellAudio.c again). Edit
  with `open(p, newline='')` or bytes, and `file` every touched file before packing.
* The cloud container restarted mid-session once (uptime 0): `/home/claude` survived, a running test
  was lost. Keep runs <= ~150 s per tool call and poll.

### 10.4 Tokyo Jungle, 2026-10-08 morning: the Survival white screen (facts 43-48)
43. **A faked import is invisible if the unresolved-NID log is capped globally.** `ppu_hle.cpp` printed the
    first 40 unresolved calls in total; one chatty NID (34 calls) used the budget and
    `cellSpursBarrierInitialize` never appeared. Now each distinct NID prints once. When a title stalls,
    list the unresolved NIDs first -- every one of them silently returned CELL_OK.
44. **Never lay a native host struct over a guest structure.** `cellSpursCreateTask` did
    `taskset->taskCount++` on a simplified host `CellSpursTaskset`; offset 4 is inside the BE `running`
    bitset, so two tasks = "task 38 running" (bytes 02 00 00 00). Symptom class: a little-endian small
    integer (01/02 00 00 00) or LE floats (`0000803F` = 1.0f, `CDCC1C41` = 9.8f) inside a guest object.
    Grep the HLE for `ptr->field =` on anything the SPU or PPU also reads.
45. **SPU task library calls validate the whole taskset header.** libsre's task-side SendSignal (used by
    barrier and event-flag wakes) GETLLARs taskset+0x00..0x7F and returns ERROR_STAT (0x80410905) if any
    running/ready/pending/signalled/waiting bit is outside `enabled`, or running&waiting / ready&pending
    overlap. Our runtime must keep those six bitsets consistent, not just the bits it uses.
46. **cellSpursBarrier layout:** 128-byte line, be u32 count @0x00, be u32 total @0x04, waiting-task bitmap
    @0x10, taskset EA @0x34, rest zero. Tasks increment count; the one that makes count == total resets it
    (-1 then 0) and SPU-signals each waiter.
47. **SPU-side signals must wake host threads.** A task signalling another task only PUTLLCs the guest
    `signalled` bit; nothing called the host condvar, so the waiter woke on its 1 s poll (1 fps). The
    PUTLLC path now kicks `spu_taskset_sig_kick()` after unlocking the line (never take the task-signal lock
    while holding a lock-line lock).
48. **Method that found it in ~2 h:** trace the stalled task's DMA (`SPU_DMATRACE_ALL=1 YDKJ_DMA_IMG=<img>`)
    -> its 64-byte descriptor (`SPU_DUMP_GET=<ea>`) names every object it touches -> trace atomics on each
    object line (`SPU_ATOM_EA=<ea> SPU_ATOM_FULL=2`) -> read the lifted SPU code at the failing branch for
    the field it compares. `SPU_TS_DUMP=1` prints taskset bitsets at each WAIT_SIGNAL.
* Session mechanics: `pip install ziglang` was not reachable this session (no PyPI through the proxy), so
  the Windows compile-check (1.4) was skipped; changes were limited to code paths whose `_WIN32` branches
  already compile. `pkill -f` killed the tool shell again (1.3) -- use `pkill -x TokyoJungleReco` (15-char
  comm name). Two runs writing the same log tag interleave; always kill -9 and wait before relaunching.

### 10.5 Tokyo Jungle, 2026-10-08 late morning: FIFO parks and the HLE audit (facts 49-59)
49. **NULLSW `draws=0` on a sampled present does not mean "no draws".** Read `win_draws`/`win_max` (draws
    since the last stat line / max per present). Flips climbing while presents stall plus "resync rescued N
    fence(s)" every frame = the FIFO walker is skipping ring content.
50. **A jump-to-self in a side buffer is not always an abandoned park.** If the ring `put` never pointed
    there, it is the end of a side buffer and the walker must return to the ring (`GCM_PARK_RETURN=1`,
    Tokyo Jungle). Waiting there (`GCM_PARK_WAIT_MS`) deadlocks it: the producer is blocked on work queued
    behind the park. The stuck-get watchdog (8 idle passes, ~30 ms) resyncs any park too, so any intentional
    FIFO wait must exempt itself.
51. **A guest `usleep` poll:** TELEM `sc141` near 100% at one lr. Find the call site with
    `grep 'ctx->lr = 0x<lr>;' recompiled/*.cpp`, then read the polled object live via `/proc/<pid>/mem`
    (guest base = first rw mapping >= 4 GB rounded UP to 4 GB; it may show as 5 GB + 2 GB mappings).
52. **A firmware getter that returns a pointer must return a guest address.** `return &s_static[i]` is
    truncated to 32 bits by the guest. Grep exported HLE functions for `return &s_`.
53. **Unregistered `*WithFlags` / `*Ex` / `*WithRevision` variants fail silently far away.**
    cellGcmMapEaIoAddressWithFlags faked OK and mapped nothing, so the GCM notify area did not exist.
    Implement every variant as a forwarder to its plain sibling.
54. **Float parameters cannot go through the generic 8-GPR HLE adapter.** Floats arrive in f1..; the PPU
    ABI still assigns them GPR slots positionally, so later integer args shift. Any HLE function with a
    float/double parameter needs a context handler (`ps3_hle_register_ctx`) reading `ctx->fpr[]`.
55. **Check the lifted caller before a struct-layout fix:** the offsets it reads confirm the layout cheaply.
56. **A host struct over guest memory is only safe while the HLE is its only reader and writer** (SPURS
    attributes: fine; tasksets, barriers, anything the SPU reads: never). `memset(p, 0, sizeof(host))` must
    use the real guest size (CellSpursTaskset = 0x1900).
57. **Turning on a subsystem exposes the rest of its imports.** Fixing cellFont init makes the title run code
    the failure used to skip; register the whole import family in the same change.
58. **CMake regenerates `ppu_hle_nids.cpp` whenever a lib `.c` changes**, so a parallel build picks up
    half-finished edits: make each edit compile on its own.
59. **Two workers, one VM:** give one worker the live runs (only one game instance on the 2-core box) and
    the other static work (audits, NID triage) with single-file `-fsyntax-only` checks and no ninja on the
    shared build dir. Integrate, rebuild once, re-run the full path, then push.
60. **Before reporting a fix, check that the user's run reached the fixed code path.** Tokyo Jungle's Survival
    loading screen waits for START on a plain white frame (its movie is not decoded), so a run that stops
    there looks exactly like the old freeze while every stage fix sits unreached. Give the user the exact
    input to make ("wait 10 s, press Enter/Start"), and grep the log for a marker that only the fixed path
    prints (here `_SendSignal(taskset=...`, `SPU-side signal`) before calling it fixed.
61. **"The game is not rendering" after a freeze fix may be a different bug.** Read [frame-draws]: Tokyo
    Jungle showed 2000-4300 draws/frame while the screen was white. Then map the pass graph before touching
    the renderer: `PASS_LOG=<gate file>` (one line per draw: colour targets, zeta, textures with location
    /1 = VRAM, /2 = main) interleaved with `NV3089_GATE=<same file>` blits, gated on for ~5 s in the scene.
    Location bits matter: `t0=0x0F110000/1` is VRAM 0xCF110000, not IO 0x0F110000.
62. **Windows compile-check without ziglang:** `git clone --depth 1 --sparse` github.com/mingw-w64/mingw-w64
    (mingw-w64-headers/include + crt), generate `_mingw.h` from `crt/_mingw.h.in` (sed the @...@ vars), then
    `clang -target x86_64-w64-mingw32 -nostdinc -isystem $(clang -print-resource-dir)/include -isystem <mwinc>
    -isystem .../crt -isystem .../include -c -o /tmp/x.o file.c`. Script: /home/claude/wincheck.sh.
63. **Post-process via SPU = surfaces in main memory.** A title that blits its frame out to main memory for an
    SPU pass (Tokyo Jungle: MLAA, two tasks, barrier) and blits the result back cannot work on a renderer that
    keeps render targets GPU-only and runs blits on the CPU. Plan for GPU-side blit ops (or a synchronous
    readback + upload) the moment NV3089 blits touch main memory and an RT. `/home/claude/vmdump.py` dumps a live
    guest surface from /proc/<pid>/mem to PNG to see what the SPU got.
64. **Debug-capture gates sized for one title silently skip the next.** The F9 frame capture required >= 500
    draws (inFamous); Tokyo Jungle's stage frames have ~120, so F9 did nothing. Now `F9_MINDRAWS`.
65. **"Nothing renders" can mean "the draws are produced by an SPU job that never ran".** Edge-style geometry:
    the PPU writes state into side command buffers, leaves jump-to-self holds and submits a SPURS job that
    patches the holds with draws. A FIFO walker that skips holds (GCM_PARK_RETURN) then shows everything except
    the world. Grep `dispatch MISS` FIRST whenever a scene is missing; `SPU_DUMP_MISS` on the user's PC already
    has the bytes (spu/misses), lift them as the next batch (fact 37).
66. **SPURS job ABI: set r1 word 1 = available stack bytes.** Jobs compiled with stack checks (`heqi` on
    xswd(r1) after each frame push, "[spu] HALT-ASSERT heqi") halt before doing any work when word 1 is 0. A job
    that runs, returns rc=0 and never issues an MFC command is the signature (SPU_MFCCMD_IMG shows 0 commands).
67. **Debugging a lifted job that silently does nothing:** SPU_MFCCMD_IMG=<img> (does it DMA at all?) ->
    SPU_PCLOG_IMG=<img> (block-level path, cheap) -> re-lift that one image with `spu_lifter.py --trace` and run
    with SPU_TRACE_IMG/SPU_TRACE_FILE: the last pc of each run names the exit (here 0x9188, a heqi assert).
68. **Change one ABI default at a time.** The r1 fix plus "give sizeStack==0 jobs the whole LS" broke the stage;
    bisecting with the env switch isolated it in one run. Keep every new default behind a switch at first.
69. **Count draws at both ends before touching a renderer.** `RSX_DRAWSTAT=1` (FIFO index/array draws, how many
    reached the backend, per 1 MB IO region) and the D3D12 `[rec-draws]` line (recorded/merged/dropped with
    reasons). Equal counts move the search upstream: the game is not submitting the geometry.
70. **SPURS job lists can live anywhere in guest memory.** A JOBLIST bound of 0x10000000 silently dropped Tokyo
    Jungle's 47 city jobs per frame -- no MISS, no error, the chain's trailing job still ran. Compare
    `dispatch HIT` counts per descriptor with the chain's JOBLIST counts. Bound guest pointers by the guest
    address space, never by one title's layout.
71. **Job binaries can live in the EBOOT's data** (job_cid at 0x002C5880). SPU_DUMP_MISS + wrap_spu_elf.py
    (--entry 0 --base 0) + build_spu_workloads.py --image-base <next> --constructor; the port CMake globs
    jobmods*_register.c and spu/spujob_* on every configure.
72. **GET_REPORT with location main (0xBAD68000)** must write the 16-byte report into the title's own IO-mapped
    buffer at the report offset; titles read it directly, not via cellGcmGetReport.
73. **"Too bright" post-processing: simulate before blaming the decompiler.** Re-run the decompiled maths on the
    captured input pass (numpy) under each blend hypothesis; an exact match to the output pass proves the
    shader. Then trace each pass's OUTPUT ALPHA to its source -- with SRC_ALPHA,ONE passes alpha is the
    strength knob; zeros in uniform-shaped constants mean "parameter not received", not a shader bug.
74. **Deferred renderers must snapshot SPU-written main-memory geometry at record time** (VTX_MAIN_SYNC): Edge
    style arenas are reused per job, and background conversion reads them after they are overwritten.
75. **Depth-only passes (colour target NONE) take their size from the surface clip**, not colour surface A;
    give them a private dummy colour target of that size or the viewport check squashes the shadow map.
76. **Three agents on a 2-core box:** one owns the game runs + ninja; the others own disjoint files and work
    from a Windows frame capture (rsxcap) with single-file wincheck. Resume them with SendMessage for
    follow-ups (they keep their context) instead of spawning fresh ones.

## 11. inFamous v102 (2026-10-08): two agents in parallel -- freeze lifecycle + CPU-side performance

### 11.1 Workload lifecycle facts (freeze agent; continue the fact numbering)
77. **Workload lifecycle HLE must be a state machine, not three no-ops.** Real libspurs: AddWorkload PREPARING ->
    RUNNABLE (published after wklInfo); ShutdownWorkload RUNNABLE -> SHUTTING_DOWN (an SPU still has it) or straight to
    REMOVABLE + wklEvent|=1; the kernel never schedules a non-RUNNABLE workload and moves SHUTTING_DOWN -> REMOVABLE when
    the last SPU leaves it; WaitForWorkloadShutdown blocks until REMOVABLE; RemoveWorkload returns
    CELL_SPURS_POLICY_MODULE_ERROR_BUSY (0x8041080A) while SHUTTING_DOWN, ERROR_STAT unless REMOVABLE, then clears the
    state byte and the wklEnabled bit. Titles loop on BUSY (inFamous func_0041D328). With no-ops, a host quantum in
    flight keeps running after the title frees the workload's memory. Error codes of these calls are the POLICY_MODULE
    family (0x804108xx), not CORE (0x804107xx).
78. **Host "SPU is running this wid" = the per-wid run flag, re-check guest state AFTER taking it.** Shutdown stores
    the state, then reads the flag; the kernel takes the flag, then re-reads the state (and the live wklInfo arg):
    a Dekker pair, so either Shutdown sees the quantum or the quantum sees the shutdown. Test it with a two-thread
    harness (kernel loop vs Add/Shutdown/Wait/Remove/free) before shipping -- cheap and decisive.
79. **Per-wid host caches must be reset on AddWorkload, keyed on the lifetime, not on the data EA.** Persistent
    policy-module contexts were reset only when the workload's data EA changed; an allocator that returns the same
    block for the next list would hand the new list the old list's claimed/staged job pipeline. Reset on every re-add
    (SPURS_WKL_ADD_FRESH) and clear readyCount/idle/contention/status/event/signal bytes.
80. **Correlation is not mechanism; ship the fix with the log line that decides it.** inFamous' T-pose followed the
    game's second CTaskMgr removal in 4/4 runs; the logs could not say whether a quantum was in flight at Shutdown.
    v102 prints it ([WKL] Shutdown ... quantum in flight YES/no, last busy run X ms ago) plus [WKL-QUIET] for a list
    that stops finding work, so the next run either confirms or retires the hypothesis.

### 11.2 Performance lessons (perf agent)
* **Read the hitch list against the debug actions first.** F9 frame captures produce 0.3-1.5 s frames and a "22 fps" window;
  play100's only gameplay-free >250 ms frames were boot, world load and the captures. Exclude them before chasing "dips".
* **Aggregate the sampler by function, in the binary.** 16-byte (rip, ret) buckets spread a flat guest workload so thin that the
  top 24 rows covered 27%. RtlLookupFunctionEntry(rip)->BeginAddress gives the host function for free (lifted guest functions are
  separate host functions); credit DLL samples to their first exe frame. `[PROF-FN]` + `_xfer/prof_fn_resolve.py`.
* **Check the compile flags of the biggest TUs.** The lifted PPU code (5 x 40 MB) was built for baseline x86-64 while the runtime
  and SPU code had AVX2: clang-cl then CALLS UCRT fma()/trunc()/nearbyint() and scalarises every per-lane byte swap. Add
  `-mavx2 -mfma -mbmi -mbmi2 -mlzcnt -mmovbe` AND `/clang:-ffp-contract=off` (clang-cl defaults to contract=on: with FMA enabled it
  would fuse a*b+c behind your back). Verify with `clang --driver-mode=cl --target=x86_64-pc-windows-msvc -### ...` and a 5-line
  test TU disassembled with llvm-objdump.
* **`__restrict` on the lifted ctx parameter does nothing** (measured: identical object): LLVM only uses noalias for an argument
  that does not escape, and every lifted function passes ctx to calls. Register caching has to be done by the lifter.
* **Always-on debug probes in a per-transfer path add up.** The SPU DMA path had ~25 lazily-initialised env checks, a YDKJ
  "poison" scan of every PUT payload (11x the cost of a 4 KB PUT) and `if (_n++ < cap)` log caps on shared statics -- a
  read-modify-write of one cache line by ~50 threads on every DMA, long after the cap. Pattern: one "any probe env set?" flag
  computed once -> a lean fast path that is the old path minus the probes, plus `if (_n < cap && _n++ < cap)` for caps.
* **Validate a runtime fast path with a stub harness, not by playing.** Include the header, stub every extern so that it hashes
  its arguments into a log, run old and new from identical random state (sizes, alignments, reserved lines, lists, malformed
  descriptors), compare memory + LS + return + log; plant a bug to prove the harness sees it (a notify in the "unreserved" branch
  was dead code single-threaded -- the first planted bug went unnoticed for exactly that reason).
* **SMT siblings are part of the budget of a 95%-busy thread.** Restricting the frame-limiting thread to P-cores does not stop a
  spinning worker from running on its sibling. Reserve a whole core: hard-affinitise the thread to both siblings and every other
  thread of the process away from them (Toolhelp rescan; remember and restore original masks so it can be A/B'd in-run).
* **Make the A/B phase sequence explicit** (`PS3_AB_SEQ=0,2,0,4`): a cycle that keeps visiting a known-bad phase wastes a third
  of the run; give each new lever its own phase index and keep the phase map in the handoff.

### 11.3 Coordinating two agents in one session (what worked)
* Give each agent a disjoint file set in the prompt (freeze: libs/spurs, spu_coherency/spurs_policy/spurs_job/spu_workload,
  lv2 sync; perf: libs/video, runtime/ppu, the SPU DMA/channel/lifted-thread files, CMake), its own container directory,
  and forbid edits to the playbook/HANDOFF/play*.cmd. Each writes HANDOFF_v<N>_<agent>.md + _xfer/playbook_add_<agent>.md;
  the coordinator merges and writes ONE launcher, so one user build + one run tests both.
* Ask for proposal diffs (_xfer/proposals/) when a lever lives in the other agent's files instead of letting both edit it.
* Both agents finished in ~11 and ~28 minutes; neither needed the other's files.

### 11.4 v102 A/B outcome and the "black screen, audio still playing" pattern
* Measure every lever in-run before keeping it: the main-core reservation (-2.5 fps) and the lean DMA path (-1.7 fps, noise-level)
  both LOST in play102's A/B; the compile-flag change (AVX2 for the lifted PPU TUs, ~30 -> ~35 fps) was the real gain.
* A renderer that only executes/presents a recorded batch when it contains a draw into a REGISTERED display buffer will, the moment
  a game frame has no such draw (movie/cutscene/offscreen-only sequence, or a misclassified surface), accumulate every later frame
  into one batch: black screen with audio, vertex arena growing to its cap ([VPVB] grew ... 12 chunks), then a dead FIFO. Guard:
  after N flips without a display draw, run and recycle the batch without presenting (ACCUM_FLIP_MAX), and log what it drew into.


## 12. inFamous v103 (2026-10-08/09): four agents -- black screen, movement freeze, FPS, independent review

Status at hand-off (nothing below has been run in the game yet; the user's play103 run decides it):
* Black screen: the permanent black (render_frame never running again) is now prevented two ways (frame split at the
  record cap, 250 ms forced frame end at a display clear) on top of v102c's flip fallback. The cause of the TRANSIENT black
  during the Triangle look-at camera is NOT found; the build detects black frames itself ([BLACK]) and auto-captures the
  first two (rsxcap/frame_200, frame_201).
* Movement freeze / T-pose: no SPURS or lock bug found; w2 "late pickups" and the w7 Add/Remove reset were retired as
  causes. Leading hypothesis: streaming/sim threads starved (lock convoy or CPU starvation). F8 now dumps every workload,
  lane and lock owner. The lwcond thundering herd (one condvar for all lwconds) was removed (LWCOND_PER_OBJ=1).
* FPS: lifted-code register caching exists and is proven correct by a differential harness, but ships OFF
  (build_rc.cmd builds a second exe for a side-by-side run). The lwcond change is the only always-on perf lever (A/B phase 8).
* The independent review (agent D) found and fixed one real defect (a split before the frame-ending display clear
  presented a black frame) and one A/B design error (phase 5 also toggled four bit-mask-gated features).
Coordination that worked: disjoint file ownership per agent, proposals for other agents' files, a reviewer that had not
seen the work, md5 verification of every device file (a re-commit of the same path once left old content on the device).

### 12.1 Black screen (agent A)
81. **A recorded-then-replayed renderer must never drop a draw at its record cap -- split the batch.** inFamous'
     record buffer (16384) was below its heaviest frames (means of 14k per 300 frames). Draws past the cap were
     discarded while their vertices were still converted, so the frame's tail (lighting, transparents, post)
     vanished, and a batch that filled before its first display draw could never meet the "frame ends at a display
     clear with display draws" rule again. Fix: at every recording entry, if the buffer is (nearly) full, execute the
     batch without Present and continue in a fresh one; carry "this frame already drew a display buffer" and the
     record count into the frame-boundary tests and the presented-buffer choice. Leave ~64 records of slack so a
     BEGIN/END merge stream can finish.
82. **A frame-boundary fallback driven by the guest's flips is blind when the guest stops flipping.** v102c's
     ticker fallback lived in the per-flip present callback; the frame clock only calls it when the flip count
     changes. Add a time-based twin at the place frames normally end (here: the display clear): no Present for N ms
     (250) -> end the frame anyway. Count which test it overrode, so the log names the real failure.
83. **Detect "black" objectively and capture it automatically.** "The screen goes black" from the user cannot be
     placed on the log timeline, and a frame counter that keeps running says nothing about the picture. A 1-in-8
     readback of the presented image (one 3.6 MB copy, averaged on a sparse grid after the next frame's GPU wait --
     no stall), a [BLACK] start/end line with what that frame drew into the display buffers, and an automatic pass
     capture of the first black frames turn the next run into the answer instead of another question.
84. **Check whether the 2D engines are used at all before blaming RT<->main-memory transfers (fact 63).** One grep
     for the always-printed first unhandled/handled NV3089/NV0039 lines settles it; inFamous issues none. The
     remaining fact-63 path is an SPU DMA GET from an RSX-local offset that is a render target -- count SPU DMA by
     1 MB of local offset ([VRAM-DMA]) and compare the hot buckets with the surface table (RT_OFFDBG) before
     writing any GPU->guest write-back.
85. **Read the pass structure of one capture before reasoning about frame boundaries.** inFamous' batch begins
     with the display clear and the composite of the PREVIOUS frame's HDR target, then renders the next scene;
     display buffers are also used as lighting intermediates. "Display draws come at the end of a frame" -- the
     assumption behind several boundary heuristics -- was false for this title.

### 12.2 Character freeze / T-pose diagnostics (agent B)
86. **Use a high-resolution clock for wait diagnostics.** GetTickCount64 ticks every 15.6 ms. A 16 ms timed
     lock then reads as 31-32 ms, and in inFamous every 10 s "[FREEZE-SLOW] mutex_lock 40x max 32 ms" was
     Bink's ordinary 16 ms timed lock. Before reading anything into a wait histogram, check whether its
     values cluster at multiples of 15.6 ms. Then switch to QPC.

87. **A "work queued but not picked up" detector must keep the LAST change time, not only the first.** A
     queue header that the producer rewrites constantly (WWS BatchJobList: ~50 changes/s with nothing
     runnable) "waits" from its first change, and the detector reports 20-90 s "late pickups" that are
     really new work found at once. Log `last change X ms before pickup`. Only "unchanged for longer than
     the gap, then found" is a missed notification.

88. **Name the object and the owner's CPU share, not just the call.** "sys_lwmutex_lock 23x max 110 ms" says
     nothing. Per object, record waiters, the caller lr and the owner's state, sampled every 100 ms: owner
     blocked in another call = convoy; owner running with ~100% thread CPU = long critical section; owner
     "running" with under 25% CPU = starved/preempted, which is a scheduling problem, not a lock bug.
     GetThreadTimes on the owner's host thread decides which.

89. **Hook the SPURS state into the user's freeze key.** When a symptom is visual and intermittent (characters
     stuck, T-pose), periodic logs rarely line up with it. Make one key press dump every workload (state,
     runs/busy, ms since the last busy run, pending queue-line changes, data head rows) and every lane's
     persistent policy-module context (pc, status, job pipeline words). Register the dump as a hook from the
     SPURS library into the runtime watchdog, so the runtime never links against a lib symbol.

90. **A per-wid reset is only per-wid if every cache it touches is indexed by wid.** Before blaming a workload's
     Add/Remove for another workload's symptom, list every table the reset writes: PM contexts [wid][lane],
     lane pools [wid], instance bytes at +wid, the wklEnabled bit in byte wid/8. In inFamous all of them are
     per-wid. The w7 correlation is a game event, not a shared-state bug.

91. **If pip or ziglang.org are blocked, get llvm-mingw from GitHub releases.**
     (mstorsjo/llvm-mingw, ucrt-ubuntu-20.04-x86_64): `x86_64-w64-mingw32-clang -c` gives the same Windows
     compile check as zig (MinGW headers, Win32 API). Compare warning counts with the unmodified file to see
     what the patch adds.

### 12.3 Performance: register caching and lwcond waits (agent C)
92. **Register caching for lifted PPU code can be done as a post-pass on the generated C, no re-lift needed.** The lifted
functions are regular (`ctx->gpr[N]`/`fpr[N]`/`cr`/`xer`, one statement sequence per line, `goto loc_X` control flow, calls
always `func_X(ctx); DRAIN_TRAMPOLINE(ctx);`), so a ~250-line Python pass can move registers into locals and keep the
hand patches in recompiled/*.cpp. Generate the copies at BUILD time (CMake add_custom_command into the build dir, option to
switch) -- shipping 175 MB of generated source through the device bridge (30 MB/file limit) is the wrong way.

93. **The sync points are not only calls that take ctx.** Hand-patch hooks without arguments can read
`g_active_ctx->gpr[...]` (inFamous: ps3_taskwait_begin -> tw_wid_of_wait reads r30). List every call identifier in the
lifted bodies, allow-list the pure helpers, treat everything else as a sync point or skip the function.

94. **A line-based dirty-set dataflow must not let a conditional call clear the dirty set.**
`if (c) { ps3_taskwait_spin(); goto L; }` runs the call on one path only; treating it as a sync for the fall-through path
dropped spills in exactly the CTaskMgr wait loop. Only a call with nothing but `ctx->lr = imm;` before it on its line counts
as unconditional. Also refuse functions whose lines are not complete statements (unbalanced braces, braceless if/else).

95. **Differential harness for a lifted-code transform (works, catches real bugs):** extract N functions twice (O_/N_
prefix), stub every callee; set every inline memory gate to 0 so all guest accesses hit harness accessors that hash
(op, addr, value) in order over a lazily random-filled 4 GB map; every stub hashes the WHOLE ctx (missing spill) then
clobbers volatile and some callee-saved registers from a PRNG seeded by that hash (missing reload); put a tick() after
every `loc_X:` label and longjmp out after a budget (register-only loops). Plant a missing spill and a missing reload to
prove it sees them (here 428 and 369 of 678 functions).

96. **NaN payloads are not a transform bug.** With random float inputs, old vs new lifted code differ in NaN quiet bit /
payload: LLVM folds `(float)(double)x` round trips once the double no longer goes through memory (keeping an sNaN
signalling -- what PPC lfs/stfs actually do) and may commute FP/VMX operands (x86 returns the first operand's NaN). Feed
the harness NaN-free floats (clear an exponent bit) and document the class instead of chasing it.

97. **Caching 32 guest registers on x86-64 is not automatically faster.** Lifted guest functions are short with a call every
~10-20 instructions; the memory helpers' cold out-of-line calls force long-lived locals into the 6 (SysV) / 8 (Win64)
callee-saved registers or the stack, so eager entry loads, exit stores and post-call reloads cost about what the removed
ctx traffic saved: a micro-benchmark gave +3% median / up to 1.4x in call-free loops. Use lazy loads (load at first read
after a sync), spill only may-dirty registers, cache only registers referenced >= 4 times, and benchmark against the old
object before shipping -- then measure in a real run; ship default OFF when the offline evidence is neutral.

98. **A compile-time lever that touches all lifted TUs cannot be A/B'd in-run without a twin.** Either link both copies
(renamed functions + second function table + dispatcher switch; ~2x compile) or compare two runs on the same scenes with
a per-run metric that is less scene-sensitive than fps: (frame mean ms) x (main-thread sample share in func_* rows).

99. **A single host condvar behind every guest condition variable is a thundering herd.** inFamous' lwcond used one
std::mutex + condvar for all lwconds: each signal woke ~24 audio/streaming waiters of OTHER lwconds. Bucket the waiter
bookkeeping by object EA (own mutex + condvar per bucket) and keep the counting logic identical; in a stress test the
same workload used 84% less CPU. Keep the old structure reachable (env + A/B phase) and let a signal post to both while
old-structure waiters exist, so a phase switch cannot lose a wake-up.

100. **Test a wait/signal primitive in its strict form.** Poll fallbacks (1 ms wake) hide lost signals; run the harness
with infinite waits so a lost wake-up becomes a stall the harness detects, include signal-after-unlock, signal_all,
signal_to, guest timeouts and live implementation switches, and plant "no notify" / "no post" bugs to prove it.

101. **A poll cap can be load-bearing semantics.** Raising the non-strict lwcond cap from 1 ms looks like a pure perf win,
but FIOS' waits are never signalled and the boot stalled when they stopped polling (v~03 history). Measure per call site
(signalled vs poll wakes) before lengthening it, and only per site.

102. **llvm-mingw needs -fms-extensions for files with __try** (clang-cl accepts them by default); compare the error set of
the original and the modified file rather than expecting zero.

### 12.4 Reviewing a multi-agent change set (agent D)
103. A/B phase indices that share a global with BIT-MASK consumers are not independent. g_ab_mask is read both as a phase
     index (== 1, ph < 5 tables) and as a bit mask ((g_ab_mask & 1) turns off v98f: SPU rc twin, interpreter fast loop,
     wrch fast path, LANEPROF every run). Before giving a feature a new phase number, grep EVERY reader of the global and
     pick a value whose bits no mask consumer tests (8 was free in v103; 5 = 0b101 was not). Otherwise the A/B compares two
     things at once.

104. "Split a batch when the buffer is full" must not split right before the op that ENDS the batch. In the D3D12 backend a
     display clear is the frame boundary and records nothing until after the boundary test, so a split there handed the
     boundary an empty batch -> render_frame_exec skipped the display copy (it lives inside `if (s_rf_count > 0)`) and
     Present showed the bare clear colour. Rule: place the capacity check immediately before the op that RECORDS, not at the
     top of every entry point; and check what the consumer does with a zero-record batch.

105. Review renderer timing fallbacks against the real op stream: inFamous issues display clears mid-frame (rsxcap
     manifest: rt=0 clears at op0, op172, op2002). Any rule of the form "a display clear after N ms ends the frame" will
     fire on those mid-frame clears after an in-frame hitch. The rsxcap manifest.txt is the quickest way to see where
     boundary candidates sit inside a frame.

106. Per-render_frame statistics ([FRAME78], [ABFPS], s_dbg_last_draws) silently change meaning when a feature adds
     non-present executes. When reviewing such a feature, list every per-exec counter and say whether it now counts parts.

107. Fast linkage check without a full link: compile old (backup) and new versions of each changed TU, diff `llvm-nm -u`
     and `llvm-nm --defined-only -g` between them, and grep the tree for a definition of every NEW undefined symbol (and
     for duplicates of every NEW defined one). C++ mangling shows up directly in nm (_Z... vs plain name), which catches a
     missing extern "C" in a header included from both C and C++.

108. Verify device md5s yourself, then stage ONE tarball of the trees you need (tar on the device into the user folder,
     stage, extract in the container) instead of staging files one by one -- 2.6 MB for ps3recomp include/runtime/libs +
     the handoff backups, 6 MB for infamous-recomp/spu. The device $HOME may have < 10 MB free; write the tarball under
     the mounted folder (_xfer/bak_<date><agent>/).

109. llvm-mingw needs -D_WIN32_WINNT=0x0A00 to match the Windows SDK default clang-cl sees (otherwise Win8+ APIs such as
     GetCurrentThreadStackLimits are "undeclared" and look like a real error under -Werror=implicit-function-declaration).

## 13. inFamous v121-v124 (2026-10-10): the "world freeze" -- an untranslated vslo/vsl pair in the lift

**Symptom (all of v96-v120):** every few seconds while moving, Cole stops moving but keeps playing his walk/run
animation; story NPCs the same; ambient NPCs flicker or despawn; camera stays live. 0.1-1.1 s, then Cole snaps on.
**Cause:** the lifter emitted `/* TODO: vmx_x1036 */ /* TODO: vmx_x452 */` (vslo + vsl) instead of code in 15
places. The game's "is world cell N ready" bitset test shifts a one-bit mask by N with exactly that pair, so it
always tested cell 0; the streaming manager held every actor until an unrelated cell settled.
**Fix:** translate the pair (generated C patched in place; ppu_disasm.py/ppu_lifter.py fixed for re-lifts).
play124: zero holds. ~20 earlier versions tuned FIOS/SPURS/locks/thread placement for this and changed nothing.

### 13.1 Facts (continue the numbering)
110. **Audit the lift for untranslated instructions before any runtime debugging.** One grep would have
     ended a two-day hunt: `grep -ho "TODO: vmx_x[0-9]*\|TODO: [a-z]\+" recompiled/*.cpp | sort | uniq -c`.
     `.word 0x...` TODOs are data words inside code sections (jump tables, constants) and are harmless; any TODO
     naming a mnemonic or `vmx_xNNN` is a silently dropped instruction. A dropped VMX op does not crash -- the
     destination register keeps its old value, so the function returns plausible but wrong answers forever.
     Make the lifter count unknown opcodes at the end of a run (or fail), and re-run the grep after every re-lift.
111. **vslo + vsl (or vsro + vsr) back to back = "shift a 128-bit value by a variable bit count".** The count is
     in byte 15 of vB: vslo/vsro use (b15 >> 3) & 15 octets, vsl/vsr use b15 & 7 bits (ISA: every byte of vB must
     hold the same count, so games splat it with lvebx + vspltb). Bitset tests (`1 << N` in a qword, and with
     the set, vcmpequw. against zero) are the common use. Encodings: primary 4, VX xo 452 vsl, 708 vsr, 1036
     vslo, 1100 vsro. inFamous: 0x10000C0C / 0x100009C4 at 0x12B728.
112. **A game that freezes its own world is usually obeying a flag; find the flag.** Animation alive + positions
     frozen + NPC spawns failing = the engine skipping entity updates on purpose. No timing/throughput fix can
     help until you know which condition it is waiting on. Do not infer from correlations (read bursts, SPU load
     -- both were real and both were effects).
113. **Method that found it in 4 short user runs (~1 h).** (1) ICALLTL=1: per-100 ms histogram of the main
     thread's indirect-call targets, with how many returned r3==0, F8 dumps the last 6 s -> a once-per-frame
     virtual stopped exactly during the freeze. (2) Same + 4-frame host backtrace per target resolved to
     func_XXXXXXXX via the sorted function table -> the per-entity update and its caller. (3) A read-only probe
     of the gate at the top of that update (evaluate the game's own getter on a scratch register copy, log every
     change with timestamps) -> the state was constant, a per-actor byte flag toggled. (4) grep the lift for
     stores to that offset -> the setter/clearer -> their decision function -> the broken callee. Each run is
     "build, play 2 min, press F8 when frozen". Tools: ppu_loader.cpp itl_* + tools/icalltl_analyze.py.
114. **Virtual calls often land on a this-adjust thunk** (`r3 -= N; tail call` via g_trampoline_fn). A probe keyed
     on the real function's address never fires; hook the trampoline drain too (v123 vs v123b).
115. **The lifted code does not set ctx->lr for bctrl.** For "who called this virtual", use the HOST return
     address in ps3_indirect_call (RtlCaptureStackBackTrace) and map it through the function table sorted by host
     address. Frames inside ps3_indirect_call itself show as host+XXXX.
116. **Constant-duration symptoms are rarely throughput.** The hitch stayed ~1 s after streaming became 4x
     faster (v119). That alone should have retired the streaming theory; record "did the symptom length change"
     for every fix attempt, not just "still there".
117. **A causal-looking test can mislead.** v114 (+8 ms per read -> hitches longer) "proved" streaming speed was
     causal. It was: slower streaming keeps the manager's G->0x104 "streaming active" window open longer, and the
     broken test only matters inside that window. True mechanism, wrong lever.

### 13.2 inFamous engine map (BCES00220) -- inFamous 2 almost certainly shares this engine
Addresses are inFamous 1 EU; for inFamous 2 find the same code by pattern (the 0x34D/0x7C offsets and the
vslo/vsl bitset idiom are the quickest anchors).
* Per-entity update: func_00274630 (reached via thunk func_004BA678, r3 -= 104), called virtually from
  func_003243F8. Gate at its top: `A = ent->0x7C; if (A && st = A->vtbl[+8](A)->+4 in 7..12 && A->byte[0x34D])
  return;` else ++ent->4 (refcount), component list ent->0x84 (next +0x28), comp->vtbl[+0x18]() = Update.
* Actor hold flag A+0x34D: set by func_002AC378 (calls A->vtbl[0x54]), cleared by func_002ADB84/88, both
  driven by func_002BF3D0(mgr, A) each frame: G = [[toc-0x7BB4]-0x7FD0]; no hold unless G->0x104 (streaming
  active); state 10: idx = func_0012CA88(G, .., 1), hold until func_0012B6F0(G, idx) (cell ready);
  other states: hold while A->0x34E && func_0012CA88(G, .., 0) == -1.
* func_0012B6F0 = cell-ready bit test (128-bit set at G, mask table 0x5A9360 = 00..01, vslo/vsl by idx).
* Actor states come from static state objects (P at 0x0074FDxx, id at P+4); actors sit in 8/9/10 for minutes.
* Character classes: secondary vtables 0x72A974 / 0x72ABD8 (subobject at +0xE8C); once-per-frame virtuals
  func_004A3CD0, func_0004A898 (useful "is the world updating" heartbeats for ICALLTL).
* Streaming: FIOS (static lib) -> psarc (infamous1.psarc_s, 64 KB zlib blocks, w0 points 2 bytes past 78 DA).
  The FIOS SPU decompress task is replaceable by FIOS_HLE=1 (native inflate, 0.12-0.36 ms per request).
* Jobs: Naughty Dog ICE (anim, batch jobs) + WWS job manager PMs; CTaskMgr workloads w1/w6 are the ones the
  main thread waits on. brb* = the audio engine (w3 BrBDblBufWrkld on SPURS instance 1).

### 13.3 Checklist for inFamous 2 (or any title on this engine)
1. Before the first boot: grep the lift for `TODO: vmx_x` / mnemonic TODOs; lifter has vsl/vsr/vslo/vsro now.
2. Carry over: FIOS_HLE (psarc inflate), SPURS lifecycle (sec. 11), frame split/forced frame end (sec. 12),
   the v104 maxContention note (parallel lanes violate maxC=1 but measured fine for inFamous).
3. If actors freeze while animating: ICALLTL=1 + F8, then find the entity-update gate (13.2) and probe it.
4. Keep ICALLTL off for normal play (it costs ~1-2 fps; [GATE] probe runs a guest getter per entity).

### 13.4 v125: performance follow-up (2026-10-10)
118. **PPU register caching (v103C, tools/ppu_regcache.py) wins in the game although offline it looked neutral:**
     same route, 20.4 fps (normal build) vs 23.1 fps (build-rc) over 11 / 28 windows, ~+12%, once the main thread is
     ~80% guest code. Micro-benchmarks of short cold paths understate it; measure in a run. Removing ~15 diagnostic
     systems gave only ~+3%.
119. **Always rerun the baseline on the same route before reading a perf result.** play125 looked 25% slower than
     play124 -- a heavier area; a play124 rerun on the same route matched it. Compare runs only route-for-route
     (or with an in-run A/B), never against yesterday's log.

120. **When the PPU waits on SPU jobs and the lanes are busy, look at the lifted SPU helpers' x86, not the
     scheduler.** Two cheap-looking helpers dominated inFamous's hot kernels: shufb (byte swaps on all three inputs and
     the output are unnecessary -- SPU_W is an involution, so the control needs no swap and the selector ^3 indexes host
     bytes) and the xfloat clamp, whose `if (global)` branch clang leaves inside every float op of a large loop (no
     unswitching), adding spills. Branch-free clamp = min_epu32(x,0xFF7FFFFF) + min_epi32(x,0x7F7FFFFF) with limits in a
     global that the off-switch rewrites. Hottest kernel -39% instructions. Check `clang -S` of one hot function
     before/after; llvm-mca on the straight-line body gives a quick cycle estimate. (v130/v131, inFamous)

---

## 14. inFamous v132-v146 (2026-10-11): plugin lift, a lifter switch bug, audio, mipmaps

From ~19-23 fps with broken audio to ~33-38 fps with mostly clean audio in one day. Facts continue the numbering.

### 14.1 SPU: code the lifter never saw
121. **Measure where SPU time goes per workload before tuning the scheduler.** LANEPROF + [TWCUR] showed the main
     thread waiting ~45% of wall on one hidden job list (w2 BatchJobList) whose lanes spent 75-82% in the SPU
     INTERPRETER. Every scheduler bit tried (hot lanes, pinning, less spinning) was noise next to that. Use a
     factorial A/B (PS3_ABX_SEQ, Gray-code phases with reversals, tools/abx_analyze.py) so each bit's effect comes
     with an error bar; 12 s phases over ~10 min resolve ~+-3%.
122. **Job "plugins" are PIC blobs DMA'd into job buffers at varying LS bases.** inFamous: 13 blobs in the EBOOT
     (header +0x10 code end, +0x14 size), called through an LS table. Lift them once in relocatable form
     (spu_lifter RELOC mode: code addresses = canonical + TLS delta) and look them up by CONTENT (header + function
     bytes), not address (tools/plug_lift.py). Reject ambiguous matches (two verified candidates) -> interpreter.
123. **A lifted region is useless if the interpreter never hands control back.** First plugin lift lost 14%: once the
     interpreter resumed mid-function (interrupt return, call return) it ran the blob to the end. Fix: every
     brsl/bisl return address is a function start, and the interpreter's decode cache flags pcs where a verified
     lifted function starts and returns to the dispatcher there. Result +7.9 fps (19.0 -> 26.8).
124. **Runtime-generated SPU stubs can be lifted as fixed regions.** pm_wwsjob builds context save/restore stubs at
     LS 0x3FEC0 (lqa/stqa $0..$75; bi $79) and runs a resume path at 0xA2C; both are constant byte sequences, matched
     only at their exact address. Find them in [spu-miss] top pcs; simulate the generator to confirm the bytes.
125. **Verify lifted SPU code offline before shipping it.** Harness (ps3recomp/tools/plug_verify): interpreter vs
     lifted from the same dumped state (SPU_FRAG_DUMP: LS + 128 GPRs) until the first exit; compare all GPRs, LS,
     exit pc. Build the interpreter with the same fp contraction as the lifted code (spu_fi is fused under default
     contraction) or 4/90 cases "fail" in the last bits. It caught the missing return-address entries (62/90 failing)
     before any game run.

### 14.2 PPU lifter: switch tables
126. **A switch whose table base comes from a TOC load must not resolve the base register to a frame restore.**
     discover_jump_tables picked `ld r30,0x180(r1)` from an early-exit epilogue (ended by a sibling tail call `b`, so
     liveness kept it) instead of the prologue `lwz r30,-0x7C1C(r2)` -> bctr became an unresolved indirect call ->
     case 0 aborted the function -> object with a zero vtable -> null-call cascade = the "random freeze after minutes".
     Fix: the two-level base scan skips `ld/lwz rX,d(r1)`. Symptom to grep: `[ppu] unresolved indirect call` to an
     address INSIDE the calling function.
127. **Never re-lift a mature port wholesale.** A fresh lift differed from the shipped files in 5286 functions
     (post-processing, hand patches). Re-lift in the cloud, diff per function, splice only the functions the fix
     changes (keep the file's line endings -- ppu_recomp_001.cpp is CRLF).

### 14.3 Audio (cellAudio) -- the order that worked
128. **"Audio breaks under load" = the SPU mixer workload missing real time, not the PPU.** Prove it before changing
     anything: [audio-rate] (late holes per 5 s) vs LANEPROF busy time of the mixer workload (inFamous: inst1 w3,
     nSpus=1, 5.33 ms blocks); holes appear when it is >90% busy. A [FREEZE] thread dump on the 3rd consecutive hole
     (ps3_freeze_dump_now, AUDIO_HOLE_DUMPS) showed every PPU sound thread idle -> the SPU stage is late.
129. **Give the mixer's SPURS kernel thread a real core.** SwitchToThread after busy passes + normal priority starved
     it. SPURS_INST1_HOT (HIGHEST priority, 2 ms PAUSE spin) + PS3_AUDIO_CORE (reserve a physical core for it):
     holes 250-450 -> 0-200 per 5 s.
130. **Holes counted in multiples of the ring size mean the consumer overtook the producer.** With an 8-block port
     ring, a late block cost 8 blocks (43 ms): once the read index passes the write head, the producer's ring math
     loses a whole lap. Fix: never consume a block that was not written -- clear consumed blocks to -0.0f (a
     sentinel that is numerically silence) and STALL that port's read index while its block is still all -0
     (AUDIO_SENTINEL, bounded by AUDIO_STALL_MAX, self-disabling if the producer stops dead). Silent share in heavy
     scenes 35% -> 2%. Raising the elastic wait (AUDIO_ELASTIC_US) is safe because it is bounded by queued slack.
131. **What did not help:** consumption lag (play late blocks LAG periods later), eager consumption ahead of the
     clock, a bigger queue. They move latency around; they cannot fix a producer below real time.
132. **Conceal what is left.** A hard cut to silence is the audible crackle. Fill a missing block with a looped pitch
     period (best normalised cross-correlation over the last 2 delivered blocks), fade after ~2 blocks, cross-fade
     into the next real block (AUDIO_PLC). The real fix is still a faster mixer workload.

### 14.4 Renderer
133. **Upload mip chains.** The D3D12 backend created every guest texture with MipLevels=1 while the title sampled
     with trilinear filters: distant geometry shimmered ("buildings flickering"), fine patterns became moire stripes,
     and the GPU read full-resolution texels everywhere. RSX stores levels packed after level 0 (each SZ level
     Morton-ordered within itself; cube faces = one whole pyramid apart, 128-aligned): rsx_texture_mip_chain.
     TEX_MIPS (v146): SZ + DXT only, BC top level 4-aligned, guard the guest range with VirtualQuery, footprints
     from GetCopyableFootprints, SRVs with all levels. If a port shows shimmer, check MipLevels first.
     (Written before the first in-game run of v146 -- confirm with play146 and update this fact.)
134. **Users cannot catch a 100 ms glitch with a hotkey; ask for a screen recording** (Win+Alt+R). Extract frames with
     ffmpeg, drop duplicate frames (60 fps capture of a 30 fps game), and look at crops frame by frame. In inFamous
     it separated real renderer bugs from the game's own streaming pop-in (detail meshes 3-6 frames after entering
     view, coarse-world stand-in meanwhile).
135. **Draw-list diffs across F9 frames need stable keys.** FP addresses alternate with the guest's FP double buffer
     and world draw counts vary with SPU culling; key on (target, VS, textures) and compare per material, or every
     draw looks like it toggles.

### 14.5 Session mechanics
* Re-committing from the same cloud staging path can write a stale copy -- commit under new names, check md5.
* Launching the same playNNN.cmd twice at once breaks ninja ("failed recompaction: Permission denied").
* Syntax-check Windows-only files in the container with mingw-w64 (`apt-get install gcc-mingw-w64-x86-64`); its
  d3d12.h is old, so only check the lines you changed.

### 14.6 Index additions (env / tags)
`PS3_ABX_SEQ`, `[ABFPS]`, tools/abx_analyze.py; `SPU_FRAG_DUMP`, `SPU_MISS_STATS`, `[spu-miss]`, `[frag]`, `[plug]`;
`SPURS_INST1_HOT`, `PS3_AUDIO_CORE`; `AUDIO_RATE`, `AUDIO_PEAK` (`[audio-ring]`), `AUDIO_AHEAD_BLOCKS`,
`AUDIO_ELASTIC_US`, `AUDIO_THREAD_BOOST`, `AUDIO_HOLE_DUMPS` (needs FREEZE_DUMP=1), `AUDIO_SENTINEL`,
`AUDIO_STALL_MAX`, `AUDIO_PLC`, `[audio-rate]`, `[audio] v145`; `SPU_DMA_FAST`, `SPU_POISON_DMA`; `TEX_MIPS`,
`[TEX] v146`; `PS3_PROF_MAIN=2` + tools/prof_resolve_map.py.

## 15. inFamous v219 (2026-10-15 night): UNATTENDED benchmarking + FIFO-thread FPS work (agent alone, user asleep)

### 15.1 The unattended bench (no player needed)
* A job runner (tools/bench/runner.ps1, started once by double-clicking ..\START_BENCH_RUNNER.cmd) executes .cmd files
  dropped into infamous-recomp\_bench\queue\ one by one (timeouts, KILL/STOP files, heartbeat, per-job logs). An agent
  that can only CLICK on the desktop (no typing into terminals) builds and runs everything through it.
* tools/bench/bench_drive.ps1 starts the game, presses CROSS through the boot notice until [FRAME78] shows world
  frames (the save auto-continues), holds the right stick for a slow continuous camera pan, runs N minutes, kills it.
  Input comes from cellPad's PAD_FILE (file-driven buttons + v219 stick hold); the host UI overlay's dialogs take the
  same input (g_pad_file_held). BENCH_SHOT=<file> dumps the presented backbuffer on request = the agent's eyes.
* Noise: ~+-0.3-0.6 fps per bit over 12-16 min of 30 s A/B phases; across RUNS the same build drifts 2-4 fps (time,
  thermals, other processes) -> only in-run A/B counts. [ABCPU] logs what the rest of the machine used per phase.
* abx_analyze.py now takes bits up to 0x40000000; the [ABFPS] key became 64-bit (bit 0x800000 made it negative and
  those phases were silently never printed -- perf218's animation-LOD A/B had no data at all).

### 15.2 Facts (continue the numbering)
136. **Find the thread the main thread waits on before optimising anything.** [REFPOLL] said 99.8 % of the main
     thread's dry fence polls happen while the FIFO thread is WALKING -> after PGO the FIFO thread (93 % busy) was the
     critical path again, not the SPU chain. Every FIFO ms became fps.
137. **Give the critical host thread a physical core.** Hybrid CPU (8P x2 + 12E), ~30 busy threads restricted to the 16
     P-core logical CPUs: reserving one P-core (both SMT siblings) for the FIFO thread = +1.9 / +2.6 fps (two runs).
     The reservation code is multi-slot now (audio mixer, FIFO, optional main thread).
138. **PGO staleness is silent and large.** Editing a function drops its profile (CFG hash) and clang optimises it as
     cold: a vectorised index-read loop turned scalar = ~15 % of the FIFO thread's samples at one instruction. Write
     hot loops with explicit intrinsics, and refresh the profile after a night of edits (merge the new training with
     the old profile so code the bench never runs keeps its counts).
139. **Write-watch (GetWriteWatch) change detection costs more than hashing.** Exact and easy (MEM_WRITE_WATCH on the
     guest reservation; 14.8k of ~14.8k batch identities/frame proven clean), but each RESET poll of ~50 MB took
     1.2 ms (dirty-bit reset = TLB shootdowns) and was SLOWER on a helper thread (-3 fps: the IPIs hit every core).
140. **Write-combined memory: build cached, copy once.** Per-draw constant slots written field by field into an upload
     heap, interleaved with guest reads, are scattered partial-line WC writes; stage in a cached block, copy the used
     ranges in one memcpy, and re-bind an identical earlier slot instead of copying again (22.7 % of VP slots).
141. **Frame order is a free predictor.** A frame issues its batches in nearly the same order as the previous one;
     remembering per batch ordinal what it touched lets you prefetch the next batches' hash slots / source lines.
142. **Measure "obvious" pipelining wins in-run, again, in the new regime.** RF_TRIPLE (3 record parities, no
     FIFO-thread GPU wait) lost 1.6 fps in b012 even with the FIFO thread on the critical path; VC_ASYNC (hash worker)
     won 0.8 but produced degenerate batches. Both stay off.
143. **Device-bridge mechanics:** committing the same staged path twice can deliver the OLD copy -- commit edits under a
     new staged file name and stage the result back to verify. The device VM shell can die mid-session (disk full);
     stage/commit + a job queue on the user's disk keeps the loop going.

### 15.2b More facts (city bench, 2026-10-15 afternoon)
* A bench that runs "while the user uses the PC" MUST ignore host keyboard/mouse (and raw input): a game window that
  gets focus reads the user's typing -> random menus (inFamous: the map opened and the whole run measured the menu).
  Check out.log for an input-device switch line after the route; check the route screenshot every run.
* Never point a bench at the user's save folder; redirect the save root (env) to bench copies first.
* Finding the player position in guest RAM: walk/stand cycles with `changed`/`same` find mostly cameras and moving
  scenery; add DIRECTION (`dec` while walking left, `inc` while walking right) -- that isolated a fixed .data global in
  4 cycles. Value search must be NaN-safe (fabs(NaN-x) > eps is FALSE).
* A position you can read is enough for automation even if you cannot write it: a closed-loop stick autopilot
  (estimate camera yaw from velocity vs stick; jump when stalled; let go when above the target) navigates rooftops,
  cars and pillars reliably, whereas timed stick scripts drift with frame rate / spawn variance.
* A per-object "LOD skip" must exclude the player explicitly (match the object's memory against the player position)
  -- size heuristics are not a proof.

### 15.3 Index additions (env / tags)
* MEMCMD=<file> (memory tool + goto autopilot, cellPad.c), SAVEDATA_ROOT=<dir> (cellSaveData.c), BENCH_GOTO (bench_drive v4), ANIM_LOD_PLAYER_POS=0 (Cole guard off), PAD_KBM=0/PAD_NO_KEYBOARD=1/PAD_RAWINPUT=0 in bench_env.
`START_BENCH_RUNNER.cmd`, tools/bench/{runner.ps1, bench_drive.ps1, bench_env.cmd, job_*.cmd, shot.sh, hotoff.py},
`_bench\queue|done|logs|runs`, `BENCH_SHOT`, `BENCH_EXE`, `AUDIO_MUTE`, `PAD_FILE` sticks, `[ABCPU]`, `[BENCH]`;
`PS3_FIFO_CORE` (default 1), `PS3_MAIN_CORE` (launchers now 1), ABX 0x2000000 / 0x4000000; `VC_WW`, `VC_WW_ASYNC`
(`[VC_WW]`, off); `VCB_DEDUP` (`[VCB_DEDUP]`, ABX 0x8000000); `FPCB_STAGE` (`[FPCB_STAGE]`, ABX 0x20000000);
`VC_SEQ` (ABX 0x10000000); `RECS_DISP_SCAN` + VCB content compare (ABX 0x40000000); texture-unit copy (ABX 0x1000000).

## 16. inFamous v220 (2026-10-15 evening): vertex-cache change detection (HANDOFF_v220_gpu_vertex.md)
144. **Attribute writers before designing change detection.** VC_WSRC (write-watch ground truth vs an SPU-PUT hook)
     showed ~100 % of the writes into vertex-source pages are SPU DMA PUTs (city: ~500 pages/frame; "other" ~0.1
     page/frame in one chunk). A page-stamp map in the PUT hook is then exact (MISSED 0 in 142 verify reports)
     at zero poll cost -- write-watch costs 1.2 ms/poll for the same answer.
145. **A big function share is not a big removable cost.** "vc_lookup + XXH3 = 25 % of the FIFO thread" was mostly
     per-batch lookup latency (~14 k batches/frame), not hashing: skipping 15 MB/frame of hashing saved ~1 % of the
     thread and 0 fps (b026c +0.5 +-0.8, b027 +0.1 +-0.8). Split a hot function by arm (tools/bench/fifoprof.py)
     before building on it; when a cost scales with a COUNT, cut the count (per-draw reuse), not the bytes.
146. **A thread that is "the critical path" can still idle.** The FIFO thread was walking 96 % of the main thread's
     waits yet idled 15-18 % in its kick wait -> FIFO speed-ups only partly reach fps.
`VC_WSRC` ([VC_WSRC]), `VC_SWD` / `VC_SWD_VERIFY` ([VC_SWD], ABX 0x100000), `g_vc_put_note` (cellGcmSys.c), tools/bench/fifoprof.py.
