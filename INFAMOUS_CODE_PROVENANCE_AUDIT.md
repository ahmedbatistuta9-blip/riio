# inFamous PS3 Recompilation: Code Provenance Audit

**Subject:** Allegation that our inFamous (BCES00220) port uses NoahBPeterson's `ps3recomp` inFamous work without credit
**Audit date:** 2026-10-11
**Scope:** Everything under `C:\Users\MitNa\Desktop\inFamous` (read-only), compared against every branch of `github.com/NoahBPeterson/ps3recomp` and its upstream, `github.com/sp00nznet/ps3recomp`
**Method:** Git forensics, exact and normalized line matching, token fingerprinting with and without identifier renaming (MOSS-style winnowing), a scan for distinctive identifiers and strings, chronology checks, and manual side-by-side review of every significant match
**Rules followed:** No source files were modified, no history was rewritten, nothing was deleted and nothing was published. The only additions to your folder are this report and `_audit_provenance\` (copies and scripts; see §9).

---

## 1. Executive summary

**Classification: NOT SUPPORTED BY THE AVAILABLE EVIDENCE.** This does **not** mean the allegation is disproven (see §9 and §10).

The key findings:

1. **Our code comes from the upstream project, not from his fork.** `ps3recomp\` is a plain clone of **`sp00nznet/ps3recomp`** at commit **`a679051`** (upstream `master`, 2026-09-29). The clone was made on **2026-10-01 23:15:59 UTC**, according to the reflog. The local repository holds one pack file, a single remote (sp00nznet), and no refs or objects from NoahBPeterson's fork. **None of Noah's 296 authored commits is reachable from our baseline.**
2. **His fork comes from the same upstream.** GitHub labels his repo "forked from sp00nznet/ps3recomp". Everything he and we have in common from `a679051` is upstream code, with copyright "Ned Heller / sp00nznet" under the MIT license, and it is not his work.
3. **No copied code was found.** Our changes amount to 71 modified files and 21 new files (+18,068 / −866 lines). They were compared with the 103,352 lines Noah added across all his branches:
   - **Line level.** 13,899 non-trivial lines that we added were checked. 165 match a line he added. Every one of them is explained by upstream code, by a single-line split or rename of upstream code, or by a line that the hardware or SDK ABI dictates (§4).
   - **Token fingerprints.** 0.23% of our non-upstream fingerprints match his, with literal tokens. The control group, other authors' independent upstream work on the same code, matches him at 0.16%. With identifiers renamed the figures are 0.64% and 0.44%. Copied code would show tens of percent per affected region. We are at background level.
   - **Game-project sources** (`main.cpp`, `stubs.cpp`, tools, tests and SPU registration code): **0** shared fingerprints.
   - **New files:** none of our 21 new file paths matches any of his 83 new file paths.
   - **His distinctive markers** do not appear anywhere in our tree. These include his ticket IDs (`T-00xx`), his environment variables (`PS3RECOMP_ENG_*`, `PS3_ALLOC_BT`, `PS3_THREAD_DUMP`, `PS3_PRX_WATCH`), his files (`spurs_kernel.c`, `guest_mem_atomic.h`, `tests/conformance/*`, `rpcs3_oracle/*`) and his data structures (`q_bind`, `color_snapshot`, the `LFQ_*` layout enum).
   - **Our backups and snapshots.** All 5,815 historical source files in `_xfer\` and `_to_delete\` were scanned, including the nested `src31*.tgz` and `v103*` tarballs. Only 0.01% of their fingerprints overlap his, and those are machine-generated lifter output and generic idioms. **No earlier version of our code contained his code that was later removed.**
4. **The strongest point for his side is real, and it is functional, not textual.** We and he fixed the **same set of bugs** in the same runtime: `ilh` splat, `mpyhha` RR form, decoding of `orbi`/`xorhi`/`xorbi`, the 8-byte `sys_lwcond_t` layout, `sys_spu_thread_bind_queue`, the SPURS policy-module `r4` layout, B8 texture remap, an FP texture-unit mask, and `_cellSpursLFQueuePushBody`. **His commit dates are earlier for most of them.** However:
   - every one of our implementations differs in structure, behavior and diagnosis from his;
   - our code comments record different symptoms and investigation paths;
   - for **lock-line striping** our version predates his by about 2.5 days, so it cannot have come from him;
   - two projects running the same game on the same base code will hit the same bugs, and the fixes follow from PS3 hardware facts, the SDK ABI, or RPCS3.
5. **Attribution obligations.** We owe the MIT notice and credit to **sp00nznet/ps3recomp (Ned Heller) and its contributors** when we distribute anything built from it. That obligation exists whatever happens with this allegation. No evidence found here creates an attribution obligation to NoahBPeterson.

---

## 2. Verified repositories and commit references

### 2.1 The accuser's repository

| Item | Verified value | How it was verified |
|---|---|---|
| Repository | `github.com/NoahBPeterson/ps3recomp` | Cloned. GitHub page: "forked from sp00nznet/ps3recomp" |
| Owner | GitHub user `NoahBPeterson`, display name "Noah Peterson", website noahpeterson.me | GitHub profile page |
| Commit identity | `Noah Peterson <NoahBPeterson1997@gmail.com>`. Commits carry `Co-Authored-By: Claude Opus 5.5` | `git log` |
| Link between `MedicalScore3474` (Reddit) and NoahBPeterson | **NOT VERIFIED.** You supplied it. His GitHub profile lists no Reddit account, and a web search found no link | §9 |
| License | MIT, "Copyright (c) 2026 Ned Heller / sp00nznet" (the upstream LICENSE, unchanged on his branches) | `git show origin/master:LICENSE`; `git diff a679051 origin/infamous/* -- LICENSE` is empty |
| His `master` | Identical to upstream `a679051`: 0 commits of his own | `git rev-list --count origin/master --not upstream/*` = 0 |

**His inFamous branches** (tips as fetched on 2026-10-11):

| Branch | Tip | Noah commits not in `a679051` | Committer dates | Nature |
|---|---|---|---|---|
| `infamous/local-patches` | `43eea50` | 86 | **2026-10-01 to 10-05** (equal to author dates) | **The original commits.** First: `0088ac9` "inFamous local patches (opencode session, 2026-09-29/30)", authored 2026-10-01 11:14 −05:00 |
| `infamous/upstream-sync` | `f17bcd3` | 98 | 2026-10-06/07 | Re-applied copies of the same patches |
| `infamous/rebase-v0.13.0` | `770660a` | 112 | 2026-10-07/08 | Rebased onto upstream v0.13.0 (`5244db9`) |

There are 296 Noah-authored commit objects in total. Most patches exist three times, once on each branch, with different hashes. All other branches on his fork (`feat/np-matching2-psnr`, `fix/jobchain-done-data2`, `pr/spurs-jobchain`, `wip/gt5p-session-diagnostics`, `ydkj-master-bringup`) are byte-identical to upstream branches. Upstream contains **0** Noah commits, so none of his work was merged into sp00nznet.

**What was publicly available, and when: NOT DETERMINABLE.** Git records author and committer dates, and both can be set by the author. A commit object cannot have been pushed before its committer date, so that date is a lower bound on publication. The actual push time is not stored in git. GitHub's events and activity API was blocked in this environment (§9).

### 2.2 Our repositories

| Item | Value | Evidence |
|---|---|---|
| Toolkit checkout | `inFamous\ps3recomp\` | `.git/config`: `origin = https://github.com/sp00nznet/ps3recomp.git` |
| HEAD | `a679051ef304555291de2eb3ec8a3dbf64a761a8` (sp00nznet master, "Merge pull request #205…", 2026-09-29 18:28:29 −07:00) | `.git/refs/heads/master` |
| Clone time | `1790896559 +0200` = **2026-10-01 23:15:59 UTC** | `.git/logs/HEAD`, the only reflog entry: `clone: from https://github.com/sp00nznet/ps3recomp.git` |
| Remote refs | Only sp00nznet branches as of the clone: `feat/np-matching2-psnr`, `fix/jobchain-done-data2`, `master`, `pr/spurs-jobchain`, `wip/gt5p-session-diagnostics`, plus tags v0.9.0 to v0.12.1. **No `infamous/*` refs** | `.git/packed-refs` |
| Objects | One pack (`pack-94c604be…`), no loose objects, no `FETCH_HEAD`, no later fetches | `ls .git/objects`, `.git/logs/refs/remotes/origin/HEAD` |
| Local commits | **None.** All of our changes are uncommitted working-tree edits | Reflog |
| Game project | `inFamous\infamous-recomp\` (not a git repo; built from `templates/project`) | README, CMakeLists |
| Submodules | None | No `.gitmodules` |

---

## 3. Development timeline

All times are UTC. "Noah" times are the **author dates of the original commits on `infamous/local-patches`**, which equal their committer dates. They are **not** publication times. "Ours" times are the **earliest file evidence** (file mtimes of backups and snapshots), plus dates written in our handoff logs. Both kinds of evidence can be edited, and neither is a VCS record.

| Date/time (UTC) | Event |
|---|---|
| 2026-09-29 | Upstream `a679051` (sp00nznet master). Noah's first commit message says his inFamous work began in an "opencode session, 2026-09-29/30" |
| 10-01 16:14 | Noah `0088ac9`: first inFamous patch set |
| 10-01 17:38 | Noah `0ee36a4`: 8-byte `sys_lwcond_t` layout |
| 10-01 21:43 | Noah `73eb3af`: `_cellSpursLFQueuePushBody` |
| 10-01 23:12 | Noah `6b3dae3`: `sys_spu_thread_bind_queue` / receive_event |
| **10-01 23:15** | **We clone sp00nznet/ps3recomp `a679051`** |
| 10-01 23:41 | `infamous-recomp\README.md` written (boot milestone) |
| 10-02 03:30 / 03:40 / 04:10 | Noah `16231f0` (orbi/xorhi/xorbi), `45f6374` (ilh/mpyhha/DP ops), `0471213` (float semantics, `_ref` helpers) |
| **10-02 03:37** | **Ours:** `_cellSpursLFQueuePushBody` exists (`_xfer\bak_1003b\cellSpurs.c`). Its implementation is entirely different from Noah's (§4.9) |
| 10-02 13:01 | Noah `c2de27d`: render-target self-reads, `rsx_fp_texture_mask`, B8 remap |
| 10-03 01:00 | Ours (handoff): "real lwcond" (`HANDOFF.md` line 2510) |
| **10-03 05:33** | **Ours:** `sys_spu_thread_bind_queue_handler` (`_xfer\bak_1003b\lv2_register.c`) |
| 10-03 14:45 | Noah `45f153b`: SPURS r4 = u64 in preferred doubleword |
| **10-03 16:46** | **Ours:** `ilh`/`mpyhha` fixes (`_xfer\bak_1003e\spu_interp.c`), and the hand-added `orbi`/`xorhi`/`xorbi` decode (`src31` snapshot, `spu_interp_tables.inc`) |
| 10-03 22:48 | Noah `5f1611f`: `_cellSpursAttributeInitialize` real ABI |
| **10-04 ~01:45 to 04:00** | **Ours:** SPURS r4 layout fix (handoff "ROOT CAUSE of the ~30 s BatchJobList stall"; `_xfer\bak_1004k\spurs_policy.c` 04:00) |
| 10-04 20:06 | Ours: DP ops in the SPU interpreter with an MXCSR switch (`_xfer\bak_1004zh\spu_interp.c`) |
| 10-04 21:28 | Ours: SSSE3 `pshufb` SPU helpers (`src31` snapshot `spu_helpers.h`) |
| 10-05 01:37 | Last original Noah commit on `local-patches` (`43eea50`) |
| **10-05 14:39 / 15:30** | **Ours: lock-line striping, 64 stripes** (`_xfer\x34\…\spu_coherency.c` mtime; handoff v32d "2026-10-05 ~17:30 CEST") |
| 10-06 00:45 | Ours: B8 remap (v44; handoff line 194) |
| 10-06 13:4x (−05:00) | Noah re-commits everything on `upstream-sync` |
| 10-06 20:56 | Noah `420afc8`: NEON forms of the integer helpers |
| 10-07 01:03 | Ours: `rsx_fp_texture_mask` (v78; `_xfer\bak_1007v82\rsx_d3d12_backend.c`) |
| 10-07 22:01 | Noah re-commits everything on `rebase-v0.13.0` |
| **10-08 03:32** | **Noah `b709a08`: lock-line striping. This is about 2.5 days AFTER ours** |
| 10-11 ~16:40 | Our handoff v139 records your rule: "DO NOT USE ANYTHING FROM NoahBPeterson's ps3recomp fork". This is the first mention of his fork anywhere in our notes |

What the timeline shows:
- Most of the overlapping functions appear in his commits **before** they appear in our files. That is consistent with copying, and also with independent parallel work on the same game.
- Lock-line striping is **ours first**.
- `_cellSpursLFQueuePushBody` was ours about 6 hours after his author date, but the two implementations share nothing (§4.9).

---

## 4. Detailed code comparison: every significant similarity

In this section, "Ours" refers to `inFamous\ps3recomp\…` as of 2026-10-11, and "His" refers to the commit cited. "Upstream" means `sp00nznet/ps3recomp@a679051`.

### 4.1 SPU decode: `orbi`, `xorhi`, `xorbi` (9 identical lines)
- **Ours:** `runtime/spu/spu_interp.c:216-218`; `spu_interp_tables.inc:203-205`, `404-406` and `470-472`.
- **His:** `16231f0` (2026-10-02 03:30 UTC); `spu_interp.c:183` and `spu_interp_tables.inc:145` on `local-patches`.
- **Identical:** `case SPU_orbi: DST = spu_orbi(A,I); break;` (and the xorhi/xorbi versions); `[SPU_orbi] = "orbi",`; `case 0x6: return SPU_orbi;`.
- **What it shows:** Very little. The `case` lines are copies of the line directly above them in upstream (`case SPU_orhi: DST = spu_orhi(A,I); break;`) with one letter changed. The helpers `spu_orbi`/`spu_xorhi`/`spu_xorbi` already existed upstream. The opcodes 0x06, 0x45 and 0x46 are fixed by the SPU ISA.
- **Evidence of independence:** His enum and name entries are inserted **in alphabetical order**, because he regenerated `spu_interp_tables.inc` from `spu_disasm.py`. Ours are **appended at the end of the enum** with the comment `/* hand-added: missing from the decoder table (op8 0x06) */`, and our decode cases sit out of numeric order after `0x44`. Copying his file would have produced his ordering.
- **Upstream origin:** Yes (pattern and helpers). **Independent implementation:** Highly plausible.

### 4.2 SPU interpreter: `ilh`, `mpyhha`, `mpyhhau`, `rothmi`, `dfceq`/`dfcgt` and similar (7 identical lines)
- **Ours:** `spu_interp.c:174, 301-319, 339-352`. **His:** `45f6374` (2026-10-02 03:40 UTC).
- **Identical:** `case SPU_ilh: DST = spu_ilh((uint16_t)I); break;`, `case SPU_mpyhha: DST = spu_mpyhha(A,B,DST); break;`, `case SPU_rothmi:…`, `case SPU_dfceq:…`, `case SPU_dfcgt:…`.
- **Differences:**
  - Ours wraps the double-precision ops in an MXCSR rounding switch (`SPU_DP(...)`); his does not.
  - Ours implements `rotmah` inline; his calls a helper.
  - Ours adds `dftsv` and a `bisled` event check; his doesn't have them.
  - His changes `rchcnt` to `spu_pref_u32`, makes `next` wrap at 0x3FFFC, and changes `mfspr`/`fscrrd`. Ours does none of these.
  - Our comments name the game symptoms: "interpreted Bink decoder (inFamous) left every other 32-px column band…" and "r70 was clobbered". His do not.
- **What it shows:** We both found the same interpreter bugs. The corrected lines are the only correct form, because each helper's signature is fixed by upstream.
- **Upstream origin:** The helpers are upstream. **Independent implementation:** Plausible; the differences show separate work.

### 4.3 SPU helper scalar references (`spu_*_ref`, 10 identical lines)
- **Ours:** `runtime/spu/spu_helpers.h:307, 421, 427, 617-635, 897-913`. **His:** `0471213` (2026-10-02 04:10 UTC) and `420afc8`.
- **What it shows:** Nothing beyond upstream. Each line is an **upstream function with `_ref` added to its name** (for example upstream `spu_helpers.h:260`, `spu_shlqbyi`). **Upstream itself already used this convention** (`spu_shufb_ref` and `#define spu_shufb_ref spu_shufb` at upstream `spu_helpers.h:204/249`).
- **Differences:** Ours provides x86 **SSSE3/AVX2** fast paths (`spu__pshufb`, `_mm_*`: 133 intrinsics in `spu_helpers_vec.h`, 0 NEON). His provides **ARM NEON** (`vaddq_u8`, `spu__perm`, `spu__iota`: 0 `_mm_`). The SIMD code cannot have been copied in either direction.
- **Upstream origin:** Yes. **Independent implementation:** Yes.

### 4.4 `rsx_fp_texture_mask` (same function name and signature; 2 identical body lines)
- **Ours:** `libs/video/rsx_fp_decompiler.c:110-132`, `.h:39`. **His:** `c2de27d` (2026-10-02 13:01 UTC), `rsx_fp_decompiler.c:110`.
- **Identical:** The signature `u32 rsx_fp_texture_mask(const u8* ucode, u32 max_bytes)`, the opcode test `if (op == OP_TEX || op == OP_TXP || op == OP_TXD || op == OP_TXL || op == OP_TXB)` and `mask |= 1u << ((w0 & FP_TEX_UNIT_MASK) >> FP_TEX_UNIT_SHIFT);`.
- **Why this is the most notable textual match:** It is the same new public function name in the same file, at the same position (directly after `rsx_fp_read_word`), for the same purpose.
- **Explanations:**
  - The name follows upstream's sibling function `rsx_fp_program_size(const u8* ucode, u32 max_bytes)`, which has the identical parameter list.
  - The opcode order in the test is the order of the upstream enum (0x17, 0x18, 0x19, 0x2F, 0x31).
  - The shift expression is upstream's own (`rsx_fp_decompiler.c:489`).
  - **His body is upstream `rsx_fp_program_size` with one `if` added. Ours is structured differently.** Ours declares two words per line, bails out with `0xFFFF` on a branch instruction (`FP_BRANCH`), returns `0xFFFF` ("all units") on truncation and on a NULL ucode, and handles constants as `(w & 3u) == FP_REG_TYPE_CONST`. His returns 0 or a partial mask.
  - Ours ships with its own validation harness, `infamous-recomp\tests\verify78.c`, which tests the conservative `0xFFFF` contract that his function does not have.
- **Upstream origin:** Name pattern, signature, constants and opcode order all come from upstream. **Independent implementation:** Plausible. **This is the item an outside reviewer is most likely to question; see §10.**

### 4.5 SPURS policy-module `r4` layout (4 near-identical lines)
- **Ours:** `runtime/spu/spurs_policy.c:412-440`. **His:** `45f153b` (2026-10-03 14:45 UTC), `spurs_policy.c:171`.
- **Identical:** `ctx->gpr[4]._u32[0] = (uint32_t)(wkl_data >> 32); … _u32[1] = (uint32_t)wkl_data; … _u32[2] = 0; … _u32[3] = 0;`.
- **What it shows:** We both corrected the same upstream lines (`{lo,lo,hi,hi}`) to the real hardware layout. Our comment cites **RPCS3 `spursKernelDispatchWorkload: gpr[4]._u64[1] = arg`**. There is only one way to write that layout into the four lanes.
- **Differences:**
  - Ours keeps an environment toggle, `SPURS_PM_R4_LEGACY`, for LBP.
  - Our diagnosis (an audit-header stomp at `hdr+0x40+16*(spuNum+hdr[0x20])` in BatchJobList) is unrelated to his (libsre conformance tests).
  - His also adds a `poll_status` parameter and an interpreter fallback. Ours does neither.
- **Upstream origin:** Hardware/RPCS3 semantics. **Independent implementation:** Plausible.

### 4.6 `sys_lwcond_t` 8-byte layout (3 identical lines)
- **Ours:** `runtime/ppu/ppu_sysprx.cpp:461-462, 646`. **His:** `0ee36a4` (2026-10-01 17:38 UTC).
- **Identical:** `vm_write32(lwcond + 0x00, lwmutex);`, `vm_write32(lwcond + 0x04, ++s_lwcond_id);`, `uint32_t lwmutex = vm_read32(lwcond + 0x00);`.
- **What it shows:** These are the minimal correct edits of upstream's lines 348/349/363 (`vm_write64(…+0x00…)`, `+0x08`). The struct layout is the SDK's.
- **Differences:** Our comment explains the fix through the 32-bit guest-pointer ABI. His cites RPCS3 `sys_lwcond.h` and FIOS `func_00442AB8`. Our wider lwcond rewrite (a real waiter registry, `LwmSlot` lock words, fair hand-off) shares no structure with his `std::condition_variable` version.
- **Upstream origin:** Yes. **Independent implementation:** Plausible.

### 4.7 `sys_spu_thread_bind_queue_handler` (name, the first four lines, and similar log text)
- **Ours:** `runtime/syscalls/lv2_register.c:934-952`. **His:** `6b3dae3` (2026-10-01 23:12 UTC), `lv2_register.c:1891` on `local-patches`.
- **Identical:** The function name; `uint32_t tid = (uint32_t)ctx->gpr[3];`; `uint32_t num = (uint32_t)ctx->gpr[5];`; `spu_thread_t* t = spu_find_thread(tid);`; the registration line.
- **Similar log text:** Ours is `"[SPU] thread_bind_queue tid=0x%X queue=0x%X spuq_num=0x%X%s\n"`. His is `"… spuq_num=0x%X -> 0x%X\n"`.
- **Explanations:**
  - The `sys_<name>_handler` naming, the `"[SPU] thread_<op> tid=0x%X queue=0x%X … %s"` log format and `spu_find_thread` all come from upstream. Compare upstream `lv2_register.c:1658`: `"[SPU] thread_connect_event tid=0x%X queue=0x%X et=0x%X spup=0x%X%s\n"`. **Our format string matches upstream's pattern, including the trailing `%s`. His departs from it.**
  - The registers are fixed by the LV2 ABI. `spuq_num` is the SDK parameter name.
- **Behavior differs:**
  - **Ours** has 8 slots, overwrites an existing binding, always returns 0, and uses struct fields `recv_bind[]` / `spuq_num` / `recv_bind_n`.
  - **His** has 16 slots, returns `EBUSY`/`ESRCH`/`ENOMEM`, uses fields `q_bind[]` / `num` / `q_bind_n`, and adds `unbind_queue`.
- **Upstream origin:** Yes. **Independent implementation:** Plausible.

### 4.8 B8 texture remap (`lanes_b8`)
- **Ours:** `libs/video/rsx_texture_layout.c:342` = `{RSX_REMAP_ONE, 0, 0, 0}`. **His:** `c2de27d`, `rsx_texture_layout.c:321` = `{3, 0, 0, 0}`.
- **What it shows:** The name follows upstream's `lanes_argb` / `lanes_g8b8` in the same function. Both sides cite RPCS3's `{ONE,R,R,R}` mapping.
- **Different symptom investigated:** We traced it through the sun-light ramp (a 512x8 B8 texture with remap 0xAAFF, so the lights went dark). He traced it through the fog/DOF lookup (a 256x256 B8 texture, so the scene went black). The values and code differ.
- **Upstream origin:** Naming from upstream; semantics from RPCS3. **Independent implementation:** Plausible.

### 4.9 `_cellSpursLFQueuePushBody`
- **Ours:** `libs/spurs/cellSpurs.c:5265-5330`. **His:** `73eb3af`, `cellSpurs.c:3178`.
- **Identical:** One line, `const uint32_t q = (uint32_t)queue_ea;`.
- **Ours:** About 60 lines. It reads `+0x0E`/`+0x00`/`+0x08`, reserves, copies, publishes, then calls `spu_taskset_signal_parked_any`.
- **His:** About 150 lines with an `LFQ_*` enum, `lfq_wake_next`, `lfq_id_addr`, direction checks, alignment checks and waiter-id arrays read out of the EDGE zlib task. The third parameter is named differently (`isBlocking` in ours, `flags` in his).
- **Independent implementation:** Clearly yes.

### 4.10 Lock-line striping (`spu_coherency.c`), where **ours came first**
- **Ours:** `runtime/spu/spu_coherency.c:37-120`. 64 stripes, 64-byte padding, a `SPU_LOCKLINE_STRIPES` toggle, and later (v100) owner tracking with `[LL-WAIT]` reports. Dated 2026-10-05.
- **His:** `b709a08`. 128-byte-aligned `ll_stripe`, `ll_take`/`ll_drop`, `ll_stripe_of`. Dated 2026-10-08 03:32 UTC.
- **Shared line:** `spu_context* c = __atomic_load_n(&s_coh_ctxs[i], __ATOMIC_ACQUIRE);`. `s_coh_ctxs` is an upstream variable, and this is the obvious atomic load of it.
- **Independent implementation:** Yes; ours predates his.

### 4.11 Other matched lines (all explained)
- **`ppu_loader.cpp:1815-1978`** (`vm_read8/16/32/64` with `vm_oob`, `ppu_rwatch_hit`, `vm_hotmap`): the same upstream lines (upstream `ppu_loader.cpp:1520-1673`) split differently.
- **`_cellSpursAttributeInitialize(CellSpursAttribute* attr, u32 revision,`:** the real SDK/RPCS3 ABI. The bodies are unrelated: ours forwards with a legacy toggle, his writes `SATTR_*` fields.
- **`SPURS_WKL_STATUS1 = 0x90` / `SPURS_WKL_EVENT1 = 0xA0`:** These fill the gap in upstream's own enum (`SPURS_WKL_STATE1 = 0x80`, `SPURS_WKL_ENABLED = 0xB0`) with RPCS3's `wklStatus1` / `wklEvent1` offsets.
- **Generic idioms:** `#include <condition_variable>`, `fprintf(stderr, "%s\n", line);`, `for (int k = 0; k < 4; k++) {`, `*out = q->buffer[q->head];`, `import spu_lifter as L`, `double t0 = now_s();`, `const u32 ea = (u32)(uintptr_t)spurs;` (appears 27 times in his own code).
- **The 42 string literals** shared with his additions: every one also exists in upstream `a679051`. They are environment-variable names such as `PPU_HOTMAP` and `SPU_DMACHK`, plus header names.

---

## 5. Significant similarities: summary table

| # | Similarity | Our file:line | His commit / file:line | Common upstream source? | Independent plausible? |
|---|---|---|---|---|---|
| 1 | `rsx_fp_texture_mask` name, signature, 2 body lines | `libs/video/rsx_fp_decompiler.c:110,121-122` | `c2de27d` `rsx_fp_decompiler.c:110` | Yes (sibling `rsx_fp_program_size`, enum, line 489) | Yes; bodies differ |
| 2 | Same interpreter fixes (`ilh`, `mpyhha`, DP, `rothmi`) | `runtime/spu/spu_interp.c:174,301-352` | `45f6374` `spu_interp.c:140,288` | Helpers upstream; ISA | Yes |
| 3 | `orbi`/`xorhi`/`xorbi` decode | `spu_interp.c:216`; `spu_interp_tables.inc:203,470` | `16231f0` `spu_interp.c:183`; `tables.inc:145` | Yes | Yes; table order differs |
| 4 | `bind_queue` handler | `runtime/syscalls/lv2_register.c:935` | `6b3dae3` `lv2_register.c:1891` | Yes (upstream log/handler pattern, line 1658) | Yes; behavior differs |
| 5 | SPURS r4 layout | `runtime/spu/spurs_policy.c:435-438` | `45f153b` `spurs_policy.c:171` | RPCS3 / hardware | Yes |
| 6 | lwcond layout | `runtime/ppu/ppu_sysprx.cpp:461-462` | `0ee36a4` (layout lines); his file at `ppu_sysprx.cpp:366` on `local-patches` | SDK struct | Yes |
| 7 | `lanes_b8` | `libs/video/rsx_texture_layout.c:342` | `c2de27d` `rsx_texture_layout.c:321` | Upstream naming; RPCS3 | Yes; values differ |
| 8 | `_ref` scalar helpers | `runtime/spu/spu_helpers.h:307-913` | `0471213`, `420afc8` | Upstream convention (`spu_shufb_ref`) | Yes; SSE vs NEON |
| 9 | Lock striping | `runtime/spu/spu_coherency.c:44` | `b709a08` | Not applicable | **Ours earlier** |
| 10 | LFQueue push | `libs/spurs/cellSpurs.c:5265` | `73eb3af` `cellSpurs.c:3178` | SDK name | Yes; unrelated designs |

---

## 6. Evidence of shared upstream sources

- **sp00nznet/ps3recomp `a679051`:** Both projects' entire baseline. It accounts for the majority of the 165 exact-match lines: 102 match upstream lines verbatim, and 26 more are fragments or `_ref`-renames of upstream lines. It also supplies the helper signatures, naming patterns (`sys_*_handler`, `lanes_*`, `*_ref`, `SPURS_WKL_*`), log formats and env-var names.
- **Code from upstream contributors** that sits in our tree is already in `a679051` and credited upstream. This includes "faithful-adopt from canersaka's fork", "JonathanDC64/ps3recomp fork (aaea4158 / eb5451b3)" and "Cherry-picked by hand from flow/live-draw 3f4bdb9". Verified with `git grep -c` on `a679051`: 4, 1, 2 and 1 hits.
- **PS3 SDK / LV2 ABI:** `sys_lwcond_t` layout, syscall register usage, `spuq_num`, `_cellSpursAttributeInitialize` and `_cellSpursLFQueuePushBody` signatures, SPURS error codes.
- **RPCS3 (consulted by both, as their comments state):** `spursKernelDispatchWorkload` r4 layout, B8 `{ONE,R,R,R}`, CellSpurs field names (`wklStatus1`, `wklEvent1`), `decode_depth24`.
- **SPU ISA:** RI10 opcodes 0x06, 0x45 and 0x46; `ilh` halfword splat; `mpyhha` RR form.
- **Same AI assistant:** His commits are co-authored by Claude Opus 5.5, and our handoffs show Claude sessions as well. With the same model, the same codebase and the same game, convergent naming and comment phrasing is more likely than it would be for two human authors.

---

## 7. Evidence for and against copying

### 7.1 The strongest case for his accusation (adversarial view)
1. **A cluster of overlapping fixes.** At least 10 separate runtime fixes or features overlap (§5), and for 8 of them his author dates are earlier, by 1 to 5 days.
2. **`rsx_fp_texture_mask`** is a new, non-SDK function name that appears in both, in the same file, at the same position.
3. **Timing.** We cloned upstream 7 hours after his first inFamous commit, while working on the same game.
4. **No VCS history for our work.** Every one of our changes is an uncommitted edit. Our chronology rests on file mtimes and on handoff notes that our own sessions wrote, and both can be edited.
5. **Unrecorded AI sessions.** Our work was done partly in Claude cloud sessions whose transcripts are not available here (§9). The handoffs note that GitHub raw content was reachable from those containers. A session reading his fork, and then reimplementing what it read, would leave exactly this pattern: same fixes, different code. That cannot be excluded by code comparison.
6. **We knew about his fork** by 2026-10-11 at the latest. That is when your rule was recorded.

### 7.2 The strongest case for independent development
1. **No textual derivation.** Line, token and renamed-token comparisons all sit at the same background level as an independent control group. A copied function, even rewritten, normally leaves long fingerprint runs. None exist.
2. **Different implementations everywhere.** For every overlapping feature our code differs in structure, data structures, behavior, edge cases and diagnostics (§4).
3. **Different investigation trails.** Our comments and handoffs record our own symptoms and addresses: Bink column bands, r70 clobber, `LS 0x816C dfs` trap, BatchJobList audit-header stomp at `0x48C001B0`, sun ramp 512x8. His record his: FIOS `func_00442AB8`, EDGE zlib task `LS 0x9B10`, fog 256x256, libsre conformance.
4. **Copying would leave artifacts that are absent.** The hand-appended, out-of-order decode-table entries (§4.1) would not exist if his regenerated table had been copied.
5. **Ours first on one item.** Lock-line striping predates his by about 2.5 days.
6. **None of his distinctive markers are present** (§1.3).
7. **Clean repository.** Our checkout contains nothing from his fork.
8. **Expected convergence.** The same game run on the same base code surfaces the same unimplemented opcodes and wrong layouts, in roughly the same order.

### 7.3 Weighing
The textual and structural evidence points to independent implementation. The chronological pattern of parallel fixes is circumstantial and fits both explanations. **No evidence was found of copying, code derivation, or presence of his repository.** Independence cannot be established with certainty, because there is no version history of our edits and the AI session records are not available.

---

## 8. Licensing and attribution

1. **Upstream (definite obligation).** Our runtime is MIT-licensed code by Ned Heller / sp00nznet and contributors. Our `ps3recomp\LICENSE`, `CONTRIBUTORS.md` and `README.md` are unchanged; only file modes differ. **Any public build or source release must include that copyright and permission notice.** The `infamous-recomp` README says "built with PS3Recomp"; a public release should name and link `sp00nznet/ps3recomp` explicitly. I did not change any files.
2. **Contributors of upstream-merged forks** (canersaka, JonathanDC64, flOw live-draw) reached us through upstream and are credited there. Keep upstream's credits intact.
3. **NoahBPeterson.** His fork is MIT-licensed, under the same upstream LICENSE with no separate copyright line added. If code of his were used, MIT would require keeping the copyright and permission notice; MIT does not require named credit beyond that. **No such code was found.** If he identifies a specific match that survives scrutiny, crediting him would be both the MIT-compliant and the courteous response.
4. **RPCS3 (GPL-2.0)** is cited in our comments as a reference. I did not audit whether any RPCS3 source text was copied; that is outside this allegation. Upstream's policy is "RPCS3 consulted as a read-only oracle; no GPL code". `tools\rpcs3.7z` is an emulator binary used as an oracle; do not redistribute it with the build.
5. **Game data.** `Infamous (Europe)…` and `BCES00220_guest_memory_*` are copyrighted Sony / Sucker Punch material and must not ship with any release.

---

## 9. Limitations and unresolved questions

- **Reddit identity:** The link between `MedicalScore3474` and `NoahBPeterson` was not verified.
- **Publication dates:** I could not determine when his commits became public. The GitHub API was blocked here and the Activity page needs JavaScript. You can check `https://github.com/NoahBPeterson/ps3recomp/activity` in a browser. It shows push times per branch, which are the real "publicly available" dates.
- **Our chronology:** There is no VCS history of our edits. Dates come from file mtimes and self-written handoff notes; both can be edited, and some were preserved by tar or copy.
- **Earlier Claude sessions:** I could not inspect them. The cloud sessions that did much of the work are not available to me, so I cannot confirm or rule out that any of them viewed his fork before 2026-10-11. The earliest surviving mention is the v139 handoff note on 2026-10-11. I did not rely on any memory of previous sessions.
- **The earlier "3 identical lines" figure** could not be reproduced or checked, because its method is unknown. This audit counts 165 raw line matches. All of them are explained in §4 and §6, and 37 remain after removing those that also exist in upstream code.
- **Not compared:**
  - The generated PPU lift (`infamous-recomp\recompiled\`, about 170 MB) was excluded. It is deterministic output of the upstream lifter run on the game binary.
  - Binary build outputs, captures and logs were excluded.
  - `tools\rpcs3\` was excluded.
  - The generated SPU lifts were scanned only as part of the backup/snapshot sweep.
- **Not checked for copying:** RPCS3, andrebrumdev/gow2-recomp (named in our handoff as README-only reference; their fork was "NOT publicly fetchable") and other forks.
- **Limits of the method:** Fingerprinting finds copied text and copied structure. It cannot detect someone reading his code and then rewriting the idea from scratch. Only process records could show that.

**Files left in your folder:** `_audit_provenance\` contains `ours_ps3recomp.tgz`, `ours_infamous.tgz`, `ours_history.tgz` (read-only copies made for the comparison) and `scripts\` (the comparison scripts). The tarballs are about 105 MB and can be deleted.

---

## 10. Final evidence-based assessment

**Allegation: "Our project uses his PS3Recomp work / is derived from his implementation."**
**Classification: NOT SUPPORTED BY THE AVAILABLE EVIDENCE.**

- **No copied code** from his fork was found in our current tree or in any of our backups and snapshots.
- **The code both projects share is upstream sp00nznet/ps3recomp**, which is not his work.
- **The remaining overlap is functional.** It consists of parallel fixes to the same bugs, written differently, and in one case ours came first. Shared hardware, SDK, RPCS3 and upstream sources fully explain it.
- **This is not a finding of proven independence.** The missing VCS history and the unavailable AI-session records mean that "we read his commits and reimplemented the fixes" cannot be excluded technically. If he has a specific commit in mind, the most likely candidates are `c2de27d` (`rsx_fp_texture_mask`, B8) and `45f6374`/`16231f0` (SPU interpreter fixes). The answer for those is in §4.1, §4.2, §4.4 and §4.8.

---

## 11. Reproducing the findings

```bash
# His repository and upstream
git clone https://github.com/NoahBPeterson/ps3recomp.git his && cd his
git remote add upstream https://github.com/sp00nznet/ps3recomp.git && git fetch upstream --tags
git log upstream/master --author=Noah --oneline | wc -l          # 0: none of his work is upstream
git rev-list --count origin/infamous/local-patches --author=Noah ^a679051   # 86
git log --all --author=Noah --format='%h %aI %cI %s' | sort -k2 | head    # first: 0088ac9 2026-10-01
git show 16231f0 45f6374 c2de27d 45f153b 0ee36a4 6b3dae3 73eb3af b709a08 # the overlapping commits

# Our checkout (on the PC, in inFamous\ps3recomp)
type .git\config            # origin = sp00nznet/ps3recomp
type .git\logs\HEAD         # single entry: clone at 1790896559 +0200
type .git\packed-refs       # no infamous/* refs
git status / git diff a679051 --stat --ignore-cr-at-eol   # our edits (all uncommitted)

# Comparison scripts (in _audit_provenance\scripts)
python3 collect.py range <snapshot-repo> a679051 ours_snapshot > ours_added.json
python3 collect.py log  <his-repo> --author=Noah origin/<each branch>  > his_added.json
python3 collect.py log  <his-repo> upstream/* --tags --not a679051    > others_post.json
python3 compare.py <dir>; python3 filter2.py <dir>        # exact / normalized lines
PYTHONHASHSEED=0 python3 agg.py <dir> literal 15; ... rename 20       # fingerprint rates vs control
python3 winnow.py <dir> 15 literal; python3 winnow.py <dir> 20 rename # per-hunk matches
python3 idents.py <dir>                                               # distinctive identifiers/strings
PYTHONHASHSEED=0 python3 histscan.py <dir> literal 15                 # backups & snapshots
```

---

## 12. Draft Reddit response

> Thanks for raising this. I'd rather settle it with specifics than leave it hanging.
>
> I checked our project against every branch of your fork (`infamous/local-patches`, `upstream-sync`, `rebase-v0.13.0`). Here's what I found:
>
> - Our runtime is a clone of upstream **sp00nznet/ps3recomp** at `a679051` (master, Sep 29). Our checkout's only remote is sp00nznet, and it holds no refs or commits from your fork. Your fork branches from that same upstream, so the code we share is sp00nznet's MIT code and its contributors' code.
> - I compared all of our changes to that base (~18k lines) against the ~100k lines your commits add. That included whitespace-normalized lines, token fingerprints, a pass with identifiers renamed, and our older backups. Overlap was at the same level as unrelated upstream contributors' work. The identical lines that do show up are upstream code or one-liners fixed by the hardware or ABI (e.g., the 8-byte `sys_lwcond_t` layout, RI10 opcodes 0x06/0x45/0x46).
> - We clearly hit many of the same inFamous bugs: `ilh`/`mpyhha`, missing `orbi`/`xorhi`/`xorbi`, SPURS r4 layout, lwcond, B8 remap. That's expected with the same game on the same base. Our fixes are implemented differently, and on at least one (lock-line striping) ours predates yours.
>
> If you can point to specific commits of yours and the files or functions in our project you think came from them, I'll look at each one and reply publicly. If anything of yours is in there, I'll credit you, no argument. Either way, our release will credit sp00nznet/ps3recomp and its contributors, as the MIT license requires.

Before posting, three things to keep in mind:
- Keep the wording "I found no…" rather than "we proved…".
- Don't claim our work was never influenced by his commits unless you know that from your own process. Code comparison can't establish it (§9).
- The reply doesn't reveal any private source code. If he asks for a specific comparison, answer it with the facts in §4.
