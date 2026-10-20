# Provenance addendum, 2026-10-15 (re-check of the current tree, v221)

Scope: today's sources (87 changed or new files under ps3recomp/ compared with upstream sp00nznet a679051, plus infamous-recomp/ sources; generated lifter output excluded) compared against NoahBPeterson/ps3recomp branch infamous/rebase-v0.13.0 (tip 770660a, 112 commits by Noah on top of upstream v0.13.0 5244db9). The tip has not changed since the Oct 11 audit. Snapshots: _audit_provenance/v221/.

* ps3recomp remote: only sp00nznet/ps3recomp. HEAD is still a679051. No refs or objects from his fork.
* Lines: 25,797 non-trivial lines we added, checked against 44,749 non-upstream lines he added. 65 exact matches: generic idioms (for loops, QueryPerformanceCounter), SDK/ABI-dictated lines, and the items already covered in audit section 4 (spu_*_ref helpers, rsx_fp_texture_mask, bind_queue handler, lwcond layout, dfceq/mpyhhau/rothmi interpreter cases).
* Token fingerprints (winnowing, k=12): 0.09% literal and 0.71% with identifiers renamed. The Oct 11 audit measured 0.23% and 0.64%; independent upstream authors match him at 0.16% and 0.44%. This is background level.
* His distinctive markers: none present. The only hits were the substring "spurs_kernel.c" inside upstream comments naming ydkj_spurs_kernel.c and flow_spurs_kernel.c, so they are false positives.
* No reference to NoahBPeterson, his GitHub or his Reddit handle in any of our sources. Since v121 every session handoff has carried the rule "DO NOT USE ANYTHING FROM NoahBPeterson's fork".

New since Oct 11 (similar name and idea, different code):
1. hle_nid_find (ppu_hle.cpp, v221B, written 2026-10-15). His function of the same name dates from 2026-10-01. Both speed up the same upstream linear scan, ps3_nid_table_find. His builds a full open-addressed index with an atomic pointer and a mutex. Ours is a 2048-entry direct-mapped memo with miss caching, an ABX/env switch and a verify mode. No shared body lines apart from two trivial guards (if (!g_hle_inited) return nullptr; and n = g_hle_nids.count). The 2654435761 multiplier is Knuth's standard constant.
2. spu_indirect_branch_slow (spu_channels.c, v183, written 2026-10-13 04:00 with its own profile rationale, perf184). His function of the same name dates from 2026-10-06. Both split the upstream resolver into a lean entry and a noinline slow path. The musttail/clang tail-call pattern is already upstream. The fast paths differ completely: ours is a hashed per-thread cache keyed on pc/image/overlay/generation, his is a code-owner and resident-slot lookup.

Assessment: unchanged from the Oct 11 audit. No copied code. Shared names and ideas come from optimising the same upstream functions with ordinary naming conventions. To avoid even name-level overlap, the two functions can be renamed (for example hle_nid_cached and spu_ib_resolve_full); this changes no behaviour.

Update 22:41: both functions renamed (hle_nid_find -> hle_nid_cached, spu_indirect_branch_slow -> spu_ib_resolve_full), so there is no name overlap left. Originals backed up in _xfer/v221_rename/. Build 109 OK.
