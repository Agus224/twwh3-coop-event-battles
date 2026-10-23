#include "bridge_core.h"
#include <string.h>
#include <math.h>
#include <stdio.h>

static char core_diag[192];

/* All offsets are tied to the SHA-256 profile checked by the Lua adapter. */
static CebPtr ptr(CebPtr p) { CebPtr v; memcpy(&v,(void *)p,sizeof(v)); return v; }
static uint32_t u32(CebPtr p) { uint32_t v; memcpy(&v,(void *)p,sizeof(v)); return v; }
static unsigned char u8(CebPtr p) { unsigned char v; memcpy(&v,(void *)p,1); return v; }
static CebResult fail(CebResult r,const char *code,const char *detail) { r.ok=0;r.code=code;r.detail=detail;return r; }
static int valid(const CebEngine *e,CebPtr p,size_t n) { return p>0xffff && n && e->readable(p,n); }
static CebPtr faction(const CebEngine *e,CebPtr force) {
    CebPtr ref=ptr(force+0x128),p;
    if(!valid(e,ref,0x18)) return 0;
    p=ptr(ref+0x10);return valid(e,p,0x1bc5)?p:0;
}
static CebPtr general(const CebEngine *e,CebPtr force) {
    CebPtr ref=ptr(force+0x110),p;
    if(!valid(e,ref,8)) return 0;
    p=ptr(ref);return valid(e,p,0x3b8)?p:0;
}
static int count_cohort(const CebEngine *e,CebPtr c,CebPtr selected,uint32_t *total,int *found) {
    uint32_t i,n;CebPtr data,f;
    if(!valid(e,c,0x428)) return 0;
    f=ptr(c+0x370);if(!valid(e,f,0x8c8)) return 0;
    ++*total;if(f==selected) *found=1;
    n=u32(c+0x414);data=ptr(c+0x418);
    if(n>64 || (n && !valid(e,data,(size_t)n*0x98))) return 0;
    for(i=0;i<n;++i) {
        f=ptr(data+(size_t)i*0x98);if(!valid(e,f,0x8c8)) return 0;
        ++*total;if(f==selected) *found=1;
    }
    return 1;
}
static int count_side(const CebEngine *e,CebPtr a,CebPtr selected,uint32_t *total,int *found) {
    uint32_t i,n;CebPtr data;
    if(!valid(e,a,0x448) || !count_cohort(e,a+8,selected,total,found)) return 0;
    n=u32(a+0x434);data=ptr(a+0x438);
    if(n>32 || n>u32(a+0x430) || (n && !valid(e,data,(size_t)n*8))) return 0;
    for(i=0;i<n;++i) if(!count_cohort(e,ptr(data+i*8),selected,total,found)) return 0;
    return 1;
}
int ceb_model_matches(const CebEngine *e,CebPtr m) {
    CebPtr pending;
    if(!valid(e,m,0x736c)) return 0;
    pending=ptr(m+0x6cb8);
    return valid(e,pending,0x2d0) && ptr(pending+0xd0)==m;
}
CebPtr ceb_resolve_model(const CebEngine *e,CebPtr block,size_t length,int *how) {
    size_t i,n=length<64?length:64;CebPtr q,m;
    *how=-1;
    if(n<8 || !valid(e,block,n)) return 0;
    for(i=0;i+8<=n;i+=8) {
        q=ptr(block+i);
        if(ceb_model_matches(e,q)) {*how=(int)i;return q;}
        if(valid(e,q,8)) {m=ptr(q);if(ceb_model_matches(e,m)) {*how=0x100+(int)i;return m;}}
    }
    return 0;
}
CebResult ceb_inspect_ex(const CebEngine *e,CebPtr model,uint32_t host_id,uint32_t ally_id,uint32_t flags) {
    CebResult r;CebPtr manager,host,ally,host_faction,ally_faction,side_a,side_b,temps;
    uint32_t i,n,total=0;int found_a=0,found_b=0;
    memset(&r,0,sizeof(r));r.code="invalid_input";r.detail="Invalid model or force identifiers";
    r.model=model;r.host_force_cqi=host_id;r.ally_force_cqi=ally_id;
    if(!host_id || !ally_id || host_id==ally_id || !valid(e,model,0x736c)) return r;
    r.pending=ptr(model+0x6cb8);
    if(!valid(e,r.pending,0x2d0)) return fail(r,"no_pending","No pending battle");
    if(ptr(r.pending+0xd0)!=model) return fail(r,"foreign_pending","Pending battle belongs to another campaign model");
    if(u32(r.pending+0xd8)!=1 || !ptr(r.pending+0x278)) return fail(r,"not_pending_quest","A pending quest battle before combat is required");
    if(u8(r.pending+0x2aa)) return fail(r,"reinforcements_filtered","This pending battle is filtering additional armies");
    manager=ptr(model+0x5bb8);
    if(!valid(e,manager,0x160)) return fail(r,"bad_force_manager","Unexpected military force manager");
    host=e->lookup_force(manager+0x120,&host_id);ally=e->lookup_force(manager+0x120,&ally_id);
    if(!valid(e,host,0x8c8) || !valid(e,ally,0x8c8) || u32(host+8)!=host_id || u32(ally+8)!=ally_id)
        return fail(r,"missing_force","The selected force no longer exists");
    r.host_force=host;r.ally_force=ally;r.ally_general=general(e,ally);
    if(!r.ally_general || !general(e,host) || !u32(ally+0x6d4) || u32(ally+0x6d4)>80)
        return fail(r,"invalid_army","A valid commanded army is required");
    if(ptr(ally+0x8a8) || ptr(host+0x8a8)) return fail(r,"temporary_army","Only real campaign armies are accepted");
    host_faction=faction(e,host);ally_faction=faction(e,ally);
    /* Accepted modes: 0 co-op (own cohort), 3 same-faction attach (single player),
     * 4 other-faction own cohort (single-player test of the co-op path). */
    if(flags!=0 && flags!=(CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH) && flags!=CEB_FLAG_OTHER_FACTION_TEST)
        return fail(r,"invalid_flags","Unknown join mode");
    /* faction+0x1bc4 is the controller type. The engine treats values below 2 as human
     * (0x1426acfea: cmp 2 / jae) and 0 as the local human (0x1426b5c8c: cmp 0 / sete): in single
     * player the player's faction is 0, in co-op each client sees itself as 0 and the other as 1. */
    if(host_faction && ally_faction)
        snprintf(core_diag,sizeof(core_diag),"host faction %llx type %u, army faction %llx type %u",
            (unsigned long long)host_faction,u8(host_faction+0x1bc4),(unsigned long long)ally_faction,u8(ally_faction+0x1bc4));
    else snprintf(core_diag,sizeof(core_diag),"faction missing: host %llx army %llx",(unsigned long long)host_faction,(unsigned long long)ally_faction);
    if(flags&CEB_FLAG_SAME_FACTION) {
        if(!host_faction || host_faction!=ally_faction || u8(host_faction+0x1bc4)>1)
            return fail(r,"not_same_human_faction",core_diag);
    } else if(flags&CEB_FLAG_OTHER_FACTION_TEST) {
        if(!host_faction || !ally_faction || host_faction==ally_faction || u8(host_faction+0x1bc4)>1)
            return fail(r,"not_other_faction",core_diag);
    } else {
        if(!host_faction || !ally_faction || host_faction==ally_faction || u8(host_faction+0x1bc4)>1 || u8(ally_faction+0x1bc4)>1)
            return fail(r,"not_two_humans",core_diag);
        if(e->at_war(ally_faction,host_faction)) return fail(r,"hostile_faction","Hostile factions cannot assist");
    }
    /* Match each character and faction context to this campaign model. */
    temps=ptr(r.ally_general+0x318);
    if(!valid(e,temps,0x98) || ptr(temps+0x90)!=model) return fail(r,"foreign_model","Army belongs to another campaign model");
    temps=ptr(r.ally_general+0x3b0);
    if(!valid(e,temps,8) || ptr(temps)!=ally) return fail(r,"general_force_mismatch","General no longer commands the selected force");
    temps=ptr(r.ally_general+0x3a0);
    if(!valid(e,temps,0x18) || ptr(temps+0x10)!=ally_faction) return fail(r,"general_faction_mismatch","General no longer belongs to the selected faction");
    n=u32(model+0x7354);temps=ptr(model+0x7358);
    if(n>256 || (n && !valid(e,temps,(size_t)n*8))) return fail(r,"bad_temporary_list","Invalid quest cleanup collection");
    for(i=0;i<n;++i) if(ptr(temps+i*8)==ally) return fail(r,"temporary_army","Army is in the quest cleanup collection");
    side_a=ptr(r.pending+0xf0);side_b=ptr(r.pending+0xf8);
    if(!count_side(e,side_a,ally,&total,&found_a) || !count_side(e,side_b,ally,&total,&found_b))
        return fail(r,"bad_participants","Unexpected participant layout");
    r.participants_before=total;r.participants_after=total;
    if(ptr(side_a+0x378)==host) r.alliance=side_a;
    else if(ptr(side_b+0x378)==host) r.alliance=side_b;
    else return fail(r,"host_not_primary","The host must be the quest's primary army");
    if(found_a || found_b) {
        int same=(r.alliance==side_a)?found_a:found_b;
        if(!same) return fail(r,"opposing_participant","Army already belongs to the opposing side");
        r.ok=1;r.code="already_joined";r.detail="Army already participates on the host side";return r;
    }
    if(flags&CEB_FLAG_ATTACH) {
        /* The army joins the host's own (primary) cohort, which must have room for one more entry. */
        if(u32(r.alliance+8+0x414)>=64) return fail(r,"participant_limit","Too many armies in the host cohort");
        r.ok=1;r.code="ready";r.detail="Real force validated; no state changed";return r;
    }
    /* A cohort represents one faction. Refuse duplicate faction cohorts. */
    n=u32(r.alliance+0x434);temps=ptr(r.alliance+0x438);
    if(n>=31) return fail(r,"participant_limit","Too many faction cohorts");
    for(i=0;i<n;++i) if(ptr(ptr(temps+i*8)+8)==ally_faction)
        return fail(r,"faction_already_present","This faction already has another army in the battle");
    r.ok=1;r.code="ready";r.detail="Real force validated; no state changed";return r;
}
CebResult ceb_inspect(const CebEngine *e,CebPtr model,uint32_t host_id,uint32_t ally_id) {
    return ceb_inspect_ex(e,model,host_id,ally_id,0);
}
CebResult ceb_join(const CebEngine *e,CebPtr model,uint32_t host_id,uint32_t ally_id) {
    return ceb_join_ex(e,model,host_id,ally_id,0);
}
static CebResult attach_force(const CebEngine *e,CebPtr model,CebResult r) {
    CebPtr primary=r.alliance+8;_Alignas(16) uint64_t entry[0x98/8];float direction[2],fallback[2];
    CebVector temporary;CebPtr temporary_entries[256];uint32_t ally_units,host_units,before,total=0;int found=0;
    if(!valid(e,primary,0x428) || ptr(primary+0x370)!=r.host_force) return fail(r,"bad_primary","Unexpected host cohort layout");
    before=u32(primary+0x414);
    if(before>=64 || before>u32(primary+0x410) || (before && !valid(e,ptr(primary+0x418),(size_t)before*0x98)))
        return fail(r,"bad_primary","Unexpected host cohort army list");
    memcpy(&temporary,(void *)(model+0x7350),sizeof(temporary));
    if(temporary.count) memcpy(temporary_entries,(void *)temporary.data,(size_t)temporary.count*8);
    ally_units=u32(r.ally_force+0x6d4);host_units=u32(r.host_force+0x6d4);
    /* 0x1426687b4: attached entries get their own direction from the general towards the battle
     * position, with the cohort direction as fallback. */
    memcpy(fallback,(void *)(primary+0x3a4),sizeof(fallback));
    if(!isfinite(fallback[0]) || !isfinite(fallback[1])) return fail(r,"bad_direction","Invalid deployment direction");
    direction[0]=fallback[0];direction[1]=fallback[1];
    if(e->reinforcement_direction(direction,r.ally_general,u32(r.pending+0xc8),fallback)!=direction ||
       !isfinite(direction[0]) || !isfinite(direction[1]) ||
       direction[0]*direction[0]+direction[1]*direction[1]<0.25f || direction[0]*direction[0]+direction[1]*direction[1]>4.0f)
        return fail(r,"bad_direction","Engine returned an invalid reinforcement direction");
    memset(entry,0,sizeof(entry));
    e->make_force_data(entry,r.ally_force,direction);
    if(ptr((CebPtr)entry)!=r.ally_force) {
        e->destroy_force_data(entry);
        return fail(r,"constructor_mismatch","Native army entry did not retain the selected force");
    }
    /* 0x1426a10b8 prepares every general of a side and observes its force before the side is built. */
    e->prepare_character(r.pending,r.ally_general,0);
    e->observe_force(r.ally_force+0x38,r.pending);
    e->push_force_data((void *)(primary+0x410),entry);
    e->destroy_force_data(entry);
    r.changed=1;
    if(u32(primary+0x414)!=before+1 || ptr(ptr(primary+0x418)+(size_t)before*0x98)!=r.ally_force) {
        r.fatal=1;return fail(r,"verification_failed","Army entry was not appended to the host cohort; reload required");
    }
    /* Recompute deployment for the host cohort, now including the new entry. */
    e->initialize_cohort(primary,r.pending);
    if(!count_side(e,r.alliance,r.ally_force,&total,&found) || !found ||
       u32(r.ally_force+0x6d4)!=ally_units || u32(r.host_force+0x6d4)!=host_units ||
       memcmp(&temporary,(void *)(model+0x7350),sizeof(temporary)) ||
       (temporary.count && memcmp(temporary_entries,(void *)temporary.data,(size_t)temporary.count*8))) {
        r.fatal=1;return fail(r,"verification_failed","Post-attach force identity or cleanup collection changed unexpectedly; reload required");
    }
    total=0;found=0;
    if(!count_side(e,ptr(r.pending+0xf0),r.ally_force,&total,&found) ||
       !count_side(e,ptr(r.pending+0xf8),r.ally_force,&total,&found) || total!=r.participants_before+1) {
        r.fatal=1;return fail(r,"verification_failed","Participant count did not increase exactly once; reload required");
    }
    *(unsigned char *)(r.pending+0x2b7)=1;
    r.participants_after=total;
    r.code="attached";r.detail="Real army attached to the host cohort; pending battle refresh requested";
    return r;
}
CebResult ceb_join_ex(const CebEngine *e,CebPtr model,uint32_t host_id,uint32_t ally_id,uint32_t flags) {
    CebResult r=ceb_inspect_ex(e,model,host_id,ally_id,flags);
    CebPtr cohort,owner;void *constructed;CebVector empty={0,0,0};float direction[2],fallback[2];
    CebVector temporary;CebPtr temporary_entries[256];uint32_t ally_units,host_units,total=0;
    int found=0;
    if(!r.ok || !strcmp(r.code,"already_joined")) return r;
    if(flags&CEB_FLAG_ATTACH) return attach_force(e,model,r);
    memcpy(&temporary,(void *)(model+0x7350),sizeof(temporary));
    if(temporary.count) memcpy(temporary_entries,(void *)temporary.data,(size_t)temporary.count*8);
    ally_units=u32(r.ally_force+0x6d4);host_units=u32(r.host_force+0x6d4);
    /* Mirror the engine's secondary-cohort path in 0x14266825c: the alliance's own
     * direction is only the fallback; the reinforcing army gets its own direction
     * from its general towards the battle position (pending+0xc8). */
    memcpy(fallback,(void *)(r.alliance+8+0x3a4),sizeof(fallback));
    if(!isfinite(fallback[0]) || !isfinite(fallback[1])) return fail(r,"bad_direction","Invalid deployment direction");
    direction[0]=fallback[0];direction[1]=fallback[1];
    if(e->reinforcement_direction(direction,r.ally_general,u32(r.pending+0xc8),fallback)!=direction ||
       !isfinite(direction[0]) || !isfinite(direction[1]) ||
       direction[0]*direction[0]+direction[1]*direction[1]<0.25f || direction[0]*direction[0]+direction[1]*direction[1]>4.0f)
        return fail(r,"bad_direction","Engine returned an invalid reinforcement direction");
    cohort=(CebPtr)e->allocate(0x428);
    if(!cohort) return fail(r,"allocation_failed","Could not allocate battle participant data");
    /* Secondary cohorts are constructed with both flags cleared (0x14266825c clears
     * them before its loop); only the primary army takes the alliance flags. */
    constructed=e->construct_cohort((void *)cohort,r.ally_general,&empty,0,0,0,direction,u32(r.pending+0xc8));
    if((CebPtr)constructed!=cohort) {
        r.fatal=1;return fail(r,"constructor_contract","Native constructor returned an unexpected object; reload required");
    }
    if(ptr(cohort+0x370)!=r.ally_force || u32(cohort+0x414)!=0) {
        e->destroy_cohort((void *)cohort);e->release((void *)cohort,0x428);
        return fail(r,"constructor_mismatch","Native constructor did not retain the selected force");
    }
    e->prepare_character(r.pending,r.ally_general,0);
    e->observe_force(r.ally_force+0x38,r.pending);
    owner=cohort;e->append_cohort((void *)(r.alliance+0x430),&owner);
    /* append consumes ownership. The pending battle destructor will destroy only
     * this metadata; it must never destroy the original campaign force. */
    if(owner) {
        r.fatal=1;return fail(r,"ownership_mismatch","Native participant ownership was not transferred; reload required");
    }
    r.changed=1;
    e->initialize_cohort(cohort,r.pending);
    if(!count_side(e,r.alliance,r.ally_force,&total,&found) || !found ||
       ptr(cohort+0x370)!=r.ally_force || u32(r.ally_force+0x6d4)!=ally_units || u32(r.host_force+0x6d4)!=host_units ||
       memcmp(&temporary,(void *)(model+0x7350),sizeof(temporary)) ||
       (temporary.count && memcmp(temporary_entries,(void *)temporary.data,(size_t)temporary.count*8))) {
        r.fatal=1;return fail(r,"verification_failed","Post-join force identity or cleanup collection changed unexpectedly; reload required");
    }
    /* Verify both sides rather than merely reporting the expected count. */
    total=0;found=0;
    if(!count_side(e,ptr(r.pending+0xf0),r.ally_force,&total,&found) ||
       !count_side(e,ptr(r.pending+0xf8),r.ally_force,&total,&found) || total!=r.participants_before+1) {
        r.fatal=1;return fail(r,"verification_failed","Participant count did not increase exactly once; reload required");
    }
    *(unsigned char *)(r.pending+0x2b7)=1;
    r.participants_after=total;
    r.code="joined";r.detail="Real army appended; pending battle refresh requested";
    return r;
}
