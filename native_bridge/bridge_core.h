#ifndef CEB_BRIDGE_CORE_H
#define CEB_BRIDGE_CORE_H
#include <stdint.h>
#include <stddef.h>

#include "ceb_version.h"
typedef uintptr_t CebPtr;
typedef struct { uint32_t capacity, count; CebPtr data; } CebVector;
typedef struct {
    void *(*allocate)(size_t);
    void (*release)(void *,size_t);
    void (*destroy_cohort)(void *);
    void *(*construct_cohort)(void *,CebPtr,CebVector *,CebPtr,unsigned char,unsigned char,const float *,uint32_t);
    CebPtr (*append_cohort)(void *,CebPtr *);
    void (*prepare_character)(CebPtr,CebPtr,unsigned char);
    uint64_t (*observe_force)(CebPtr,CebPtr);
    void (*initialize_cohort)(CebPtr,CebPtr);
    CebPtr (*lookup_force)(CebPtr,const uint32_t *);
    unsigned char (*at_war)(CebPtr,CebPtr);
    /* 0x142692774: unit direction from a general towards the battle position, with a
     * fallback when both are too close. The engine computes every secondary cohort
     * (reinforcing army) direction with it in the alliance constructor 0x14266825c. */
    float *(*reinforcement_direction)(float *,CebPtr,uint32_t,const float *);
    /* Same-faction armies of a cohort ("attached" forces, like a garrison beside the defending
     * army): 0x1426687b4 builds each 0x98-byte entry with 0x142669900(entry, force, &direction),
     * appends a copy with 0x14263f6b0(&cohort->attached at +0x410, &entry) and destroys the
     * temporary with 0x142676720. The cohort initializer then gives every entry its deployment. */
    void *(*make_force_data)(void *,CebPtr,const float *);
    void (*push_force_data)(void *,const void *);
    void (*destroy_force_data)(void *);
    int (*readable)(CebPtr,size_t);
} CebEngine;
typedef struct {
    int ok, changed, fatal;
    const char *code, *detail;
    uint32_t host_force_cqi, ally_force_cqi, participants_before, participants_after;
    CebPtr model,pending,alliance,host_force,ally_force,ally_general;
} CebResult;

/* inspect never invokes a mutation operation. join only accepts a validated pending
 * quest and uses the game's allocator/constructors; real forces never enter the
 * mission's temporary-force collection at model+0x7350. */
CebResult ceb_inspect(const CebEngine *,CebPtr,uint32_t,uint32_t);
/* The layout of the Lua episodic_scripting userdata was never observed in game. The adapter
 * passes its block; each qword of the first 64 bytes is tried as the model and through one
 * dereference. A candidate is accepted only if its pending battle points back to it
 * (pending+0xd0 == model), so a pending battle must exist. *how = byte offset, +0x100 when
 * dereferenced, -1 when nothing matched. */
int ceb_model_matches(const CebEngine *,CebPtr);
CebPtr ceb_resolve_model(const CebEngine *,CebPtr,size_t,int *);
CebResult ceb_join(const CebEngine *,CebPtr,uint32_t,uint32_t);
/* Single-player mode: the selected army belongs to the host's own (human) faction. Only valid
 * together with ATTACH (flags 3), as the engine keeps one cohort per faction. */
#define CEB_FLAG_SAME_FACTION 1u
/* Attach the army to the host's own cohort (deploys with the host army, like a garrison) instead of
 * a separate cohort. Same faction only (flags 3): see CEB_FLAG_OTHER_FACTION_TEST. */
#define CEB_FLAG_ATTACH 2u
/* Single-player test only: an army of another faction (AI, possibly at war) joins in its own
 * cohort, exactly like a co-op ally (mode 0) but without the human checks. Never with ATTACH: the
 * engine looks up a cohort by each army's faction (0x1426ac2b4), so an army of another faction
 * attached to the host cohort crashes the game (null cohort at 0x1420d14c1, seen in game). */
#define CEB_FLAG_OTHER_FACTION_TEST 4u
CebResult ceb_inspect_ex(const CebEngine *,CebPtr,uint32_t,uint32_t,uint32_t);
CebResult ceb_join_ex(const CebEngine *,CebPtr,uint32_t,uint32_t,uint32_t);
#endif
