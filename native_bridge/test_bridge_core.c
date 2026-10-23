#include "bridge_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* The fake engine owns a bounded registry. readable never accepts arbitrary
 * process addresses, so malformed-pointer cases cannot dereference the host. */
typedef struct { unsigned char *p; size_t n; } Block;
static Block blocks[80];
static size_t block_count;
static unsigned int checks, failures;
static unsigned int allocations, releases, destroys, appends, prepares, observes, initializes;
static int hostile, allocation_fail, constructor_mismatch, constructor_contract, ownership_fail, initialize_tamper;
static CebPtr model, manager, pending, side_a, side_b, host, ally, enemy;
static CebPtr host_faction, ally_faction, enemy_faction, ally_general;
static CebPtr context, temporary_data, extra_data, created;
static CebPtr observed_subject, observed_listener, initialized_cohort;
static unsigned char captured_flag1, captured_flag2;
static float captured_direction[2];
static uint32_t captured_coordinate;
static unsigned int directions;static int direction_mode;
static CebPtr direction_general;static uint32_t direction_coordinate;static float direction_fallback[2];

#define EXPECT(test) do { ++checks; if(!(test)) { ++failures; \
    printf("FAIL line %d: %s\n",__LINE__,#test); } } while(0)
static void putp(CebPtr at,CebPtr value) { memcpy((void *)at,&value,sizeof(value)); }
static void put32(CebPtr at,uint32_t value) { memcpy((void *)at,&value,sizeof(value)); }
static CebPtr getp(CebPtr at) { CebPtr value;memcpy(&value,(void *)at,sizeof(value));return value; }
static uint32_t get32(CebPtr at) { uint32_t value;memcpy(&value,(void *)at,sizeof(value));return value; }
static CebPtr reserve(size_t n) {
    unsigned char *p=(unsigned char *)calloc(1,n);
    if(!p || block_count>=sizeof(blocks)/sizeof(blocks[0])) exit(2);
    blocks[block_count].p=p;blocks[block_count].n=n;++block_count;
    return (CebPtr)p;
}
static void forget(void *p) {
    size_t i;
    for(i=0;i<block_count;++i) if(blocks[i].p==(unsigned char *)p) {
        free(p);blocks[i]=blocks[--block_count];return;
    }
    EXPECT(0);
}
static int readable(CebPtr p,size_t n) {
    size_t i;
    for(i=0;i<block_count;++i) {
        CebPtr start=(CebPtr)blocks[i].p;
        if(p>=start && p-start<=blocks[i].n && n<=blocks[i].n-(size_t)(p-start)) return 1;
    }
    return 0;
}
static void *allocate(size_t n) {
    ++allocations;if(allocation_fail) return NULL;
    created=reserve(n);return (void *)created;
}
static void release(void *p,size_t n) { EXPECT(n==0x428);++releases;forget(p); }
static void destroy(void *p) { EXPECT((CebPtr)p==created);++destroys; }
static void *construct(void *p,CebPtr general,CebVector *empty,CebPtr unused,
    unsigned char flag1,unsigned char flag2,const float *direction,uint32_t coordinate) {
    EXPECT((CebPtr)p==created);EXPECT(general==ally_general);EXPECT(unused==0);
    EXPECT(empty->capacity==0 && empty->count==0 && empty->data==0);
    if(constructor_contract) return NULL;
    captured_flag1=flag1;captured_flag2=flag2;
    memcpy(captured_direction,direction,sizeof(captured_direction));captured_coordinate=coordinate;
    putp((CebPtr)p,context);putp((CebPtr)p+8,ally_faction);
    putp((CebPtr)p+0x370,constructor_mismatch?host:ally);
    return p;
}
static CebPtr append(void *vector,CebPtr *owner) {
    CebPtr address=(CebPtr)vector;
    uint32_t count=get32(address+4),capacity=get32(address);
    CebPtr data=getp(address+8);
    ++appends;EXPECT(address==side_a+0x430);EXPECT(count<capacity);
    if(ownership_fail) return 0;
    putp(data+(size_t)count*8,*owner);*owner=0;put32(address+4,count+1);
    return data+(size_t)count*8;
}
static void prepare(CebPtr p,CebPtr general,unsigned char mode) {
    ++prepares;EXPECT(p==pending && general==ally_general && mode==0);
}
static uint64_t observe(CebPtr subject,CebPtr listener) {
    ++observes;observed_subject=subject;observed_listener=listener;return 0;
}
static void initialize(CebPtr cohort,CebPtr p) {
    ++initializes;initialized_cohort=cohort;EXPECT(p==pending);
    if(initialize_tamper==1) putp(temporary_data,ally);
    if(initialize_tamper==2) put32(ally+0x6d4,21);
    if(cohort==side_a+8) { EXPECT(get32(side_a+0x41c)==1 && getp(getp(side_a+0x420))==ally); return; }
    EXPECT(get32(side_a+0x434)==1);EXPECT(getp(extra_data)==cohort);
    if(initialize_tamper==3) put32(side_a+0x434,0);
}
static CebPtr lookup(CebPtr collection,const uint32_t *id) {
    EXPECT(collection==manager+0x120);
    if(*id==72) return host;if(*id==99) return ally;return 0;
}
static unsigned char at_war(CebPtr first,CebPtr second) {
    EXPECT(first==ally_faction && second==host_faction);return (unsigned char)hostile;
}
static float *reinforcement_direction(float *out,CebPtr general,uint32_t coordinate,const float *fallback) {
    ++directions;direction_general=general;direction_coordinate=coordinate;
    memcpy(direction_fallback,fallback,sizeof(direction_fallback));
    if(direction_mode==1) {out[0]=NAN;out[1]=0.0f;return out;}
    if(direction_mode==2) {out[0]=0.0f;out[1]=0.0f;return out;}
    if(direction_mode==3) return NULL;
    out[0]=-0.8f;out[1]=0.6f;return out;
}
static unsigned int makes,pushes,entry_destroys;static int make_mismatch,push_fail;
static void *make_entry(void *out,CebPtr force,const float *dir) {
    ++makes;EXPECT(dir!=NULL && fabsf(dir[0]+0.8f)<1e-6f);
    if(!make_mismatch) putp((CebPtr)out,force);
    return out;
}
static void push_entry(void *vec,const void *entry) {
    CebPtr v=(CebPtr)vec;uint32_t cap=get32(v),count=get32(v+4);CebPtr data=getp(v+8);
    ++pushes;EXPECT(v==side_a+8+0x410);
    if(push_fail) return;
    EXPECT(count<cap);memcpy((void *)(data+(size_t)count*0x98),entry,0x98);put32(v+4,count+1);
}
static void destroy_entry(void *entry) { (void)entry;++entry_destroys; }
static CebEngine engine={allocate,release,destroy,construct,append,prepare,observe,initialize,lookup,at_war,reinforcement_direction,make_entry,push_entry,destroy_entry,readable};

static CebPtr make_force(uint32_t id,CebPtr faction,CebPtr *general_out) {
    CebPtr force=reserve(0x8c8),ref=reserve(0x18),general=reserve(0x3b8);
    CebPtr general_ref=reserve(8),force_ref=reserve(8);
    put32(force+8,id);put32(force+0x6d4,20);
    putp(force+0x128,ref);putp(ref+0x10,faction);
    putp(force+0x110,general_ref);putp(general_ref,general);
    putp(general+0x318,context);putp(general+0x3a0,ref);
    putp(general+0x3b0,force_ref);putp(force_ref,force);
    if(general_out) *general_out=general;
    return force;
}
static void reset(void) {
    while(block_count) { free(blocks[--block_count].p); }
    allocations=releases=destroys=appends=prepares=observes=initializes=0;
    hostile=allocation_fail=constructor_mismatch=constructor_contract=ownership_fail=initialize_tamper=0;
    directions=0;direction_mode=0;direction_general=0;direction_coordinate=0;
    captured_flag1=captured_flag2=0;created=0;
    model=reserve(0x736c);manager=reserve(0x160);pending=reserve(0x2d0);
    context=reserve(0x98);putp(context+0x90,model);
    side_a=reserve(0x448);side_b=reserve(0x448);
    host_faction=reserve(0x1bc5);ally_faction=reserve(0x1bc5);enemy_faction=reserve(0x1bc5);
    *(unsigned char *)(host_faction+0x1bc4)=1;*(unsigned char *)(ally_faction+0x1bc4)=1;
    *(unsigned char *)(enemy_faction+0x1bc4)=2;
    host=make_force(72,host_faction,NULL);ally=make_force(99,ally_faction,&ally_general);
    enemy=make_force(100,enemy_faction,NULL);
    putp(model+0x5bb8,manager);putp(model+0x6cb8,pending);
    putp(pending+0xd0,model);put32(pending+0xd8,1);putp(pending+0x278,context);
    put32(pending+0xc8,0x12345678);putp(pending+0xf0,side_a);putp(pending+0xf8,side_b);
    putp(side_a+8,context);putp(side_a+0x10,host_faction);putp(side_a+0x378,host);
    putp(side_b+8,context);putp(side_b+0x10,enemy_faction);putp(side_b+0x378,enemy);
    extra_data=reserve(32*8);put32(side_a+0x430,32);putp(side_a+0x438,extra_data);
    /* host (primary) cohort attached-army list at cohort+0x410 = alliance+0x418 */
    put32(side_a+0x418,4);put32(side_a+0x41c,0);putp(side_a+0x420,reserve(4*0x98));
    makes=pushes=entry_destroys=0;make_mismatch=push_fail=0;
    temporary_data=reserve(16);put32(model+0x7350,2);put32(model+0x7354,1);
    putp(model+0x7358,temporary_data);putp(temporary_data,enemy);
    {float direction[2]={0.6f,0.8f};memcpy((void *)(side_a+8+0x3a4),direction,sizeof(direction));}
    *(unsigned char *)(side_a+8+0x408)=1;*(unsigned char *)(side_a+8+0x409)=0;
}
static void expect_code(CebResult r,const char *code) {
    if(strcmp(r.code,code)) printf("  got %s expected %s\n",r.code,code);
    EXPECT(!r.ok);EXPECT(!r.changed);EXPECT(strcmp(r.code,code)==0);
    EXPECT(allocations==0 && appends==0 && prepares==0 && observes==0 && initializes==0);
}
static void validation_cases(void) {
    CebResult r;
    reset();putp(model+0x6cb8,0);expect_code(ceb_inspect(&engine,model,72,99),"no_pending");
    reset();putp(pending+0xd0,0);expect_code(ceb_inspect(&engine,model,72,99),"foreign_pending");
    reset();put32(pending+0xd8,2);expect_code(ceb_inspect(&engine,model,72,99),"not_pending_quest");
    reset();putp(pending+0x278,0);expect_code(ceb_inspect(&engine,model,72,99),"not_pending_quest");
    reset();*(unsigned char *)(pending+0x2aa)=1;expect_code(ceb_join(&engine,model,72,99),"reinforcements_filtered");
    reset();hostile=1;expect_code(ceb_join(&engine,model,72,99),"hostile_faction");
    reset();*(unsigned char *)(ally_faction+0x1bc4)=2;expect_code(ceb_join(&engine,model,72,99),"not_two_humans");
    /* 0 = local human, 1 = remote human: both accepted; 2+ = AI */
    reset();*(unsigned char *)(ally_faction+0x1bc4)=0;r=ceb_inspect(&engine,model,72,99);EXPECT(r.ok && !strcmp(r.code,"ready"));
    reset();*(unsigned char *)(host_faction+0x1bc4)=0;r=ceb_inspect(&engine,model,72,99);EXPECT(r.ok && !strcmp(r.code,"ready"));
    reset();*(unsigned char *)(host_faction+0x1bc4)=3;r=ceb_join(&engine,model,72,99);
    EXPECT(!strcmp(r.code,"not_two_humans") && strstr(r.detail,"type 3")!=NULL && allocations==0);
    reset();putp(ally+0x8a8,context);expect_code(ceb_join(&engine,model,72,99),"temporary_army");
    reset();putp(temporary_data,ally);expect_code(ceb_join(&engine,model,72,99),"temporary_army");
    reset();put32(ally+8,123);expect_code(ceb_join(&engine,model,72,99),"missing_force");
    reset();expect_code(ceb_join(&engine,model,72,101),"missing_force");
    reset();putp(ally_general+0x318,0x100000);expect_code(ceb_join(&engine,model,72,99),"foreign_model");
    reset();putp(ally_general+0x3b0,0);expect_code(ceb_join(&engine,model,72,99),"general_force_mismatch");
    reset();putp(ally_general+0x3a0,0);expect_code(ceb_join(&engine,model,72,99),"general_faction_mismatch");
    reset();put32(side_a+0x434,33);expect_code(ceb_join(&engine,model,72,99),"bad_participants");
    reset();putp(side_a+0x438,0x100000);put32(side_a+0x434,1);
    expect_code(ceb_join(&engine,model,72,99),"bad_participants");
    reset();putp(side_b+0x378,ally);expect_code(ceb_join(&engine,model,72,99),"opposing_participant");
    reset();{float direction[2]={NAN,0.0f};memcpy((void *)(side_a+8+0x3a4),direction,sizeof(direction));}
    expect_code(ceb_join(&engine,model,72,99),"bad_direction");
    reset();r=ceb_inspect(&engine,model,72,99);EXPECT(r.ok && !r.changed);
    EXPECT(strcmp(r.code,"ready")==0 && r.participants_before==2 && r.participants_after==2);
    EXPECT(allocations==0 && appends==0 && prepares==0 && observes==0 && initializes==0);
}
static void successful_join(void) {
    unsigned char host_before[0x8c8],ally_before[0x8c8],temp_before[16];
    CebResult r,again;
    reset();memcpy(host_before,(void *)host,sizeof(host_before));
    memcpy(ally_before,(void *)ally,sizeof(ally_before));memcpy(temp_before,(void *)temporary_data,sizeof(temp_before));
    r=ceb_join(&engine,model,72,99);
    EXPECT(r.ok && r.changed && !r.fatal && !strcmp(r.code,"joined"));
    EXPECT(r.participants_before==2 && r.participants_after==3);
    EXPECT(allocations==1 && releases==0 && destroys==0 && appends==1);
    EXPECT(prepares==1 && observes==1 && initializes==1);
    EXPECT(observed_subject==ally+0x38 && observed_listener==pending && initialized_cohort==created);
    EXPECT(get32(side_a+0x434)==1 && getp(extra_data)==created && getp(created+0x370)==ally);
    /* secondary cohort: both flags cleared, own direction from the engine helper */
    EXPECT(captured_flag1==0 && captured_flag2==0 && captured_coordinate==0x12345678);
    EXPECT(directions==1 && direction_general==ally_general && direction_coordinate==0x12345678);
    EXPECT(direction_fallback[0]==0.6f && direction_fallback[1]==0.8f);
    EXPECT(captured_direction[0]==-0.8f && captured_direction[1]==0.6f);
    EXPECT(*(unsigned char *)(pending+0x2b7)==1);
    EXPECT(memcmp(host_before,(void *)host,sizeof(host_before))==0);
    EXPECT(memcmp(ally_before,(void *)ally,sizeof(ally_before))==0);
    EXPECT(memcmp(temp_before,(void *)temporary_data,sizeof(temp_before))==0);
    EXPECT(getp(model+0x7358)==temporary_data && get32(model+0x7354)==1 && get32(model+0x7350)==2);
    again=ceb_join(&engine,model,72,99);
    EXPECT(again.ok && !again.changed && !strcmp(again.code,"already_joined"));
    EXPECT(again.participants_before==3 && again.participants_after==3);
    EXPECT(allocations==1 && appends==1 && observes==1 && initializes==1);
}
static void mutation_failures(void) {
    CebResult r;int mode;
    for(mode=1;mode<=3;++mode) {
        reset();direction_mode=mode;r=ceb_join(&engine,model,72,99);
        EXPECT(!r.ok && !r.changed && !r.fatal && !strcmp(r.code,"bad_direction"));
        EXPECT(directions==1 && allocations==0 && releases==0 && appends==0 && observes==0);
    }
    reset();allocation_fail=1;r=ceb_join(&engine,model,72,99);
    EXPECT(!r.ok && !r.changed && !strcmp(r.code,"allocation_failed"));
    EXPECT(allocations==1 && releases==0 && appends==0 && observes==0);
    reset();constructor_mismatch=1;r=ceb_join(&engine,model,72,99);
    EXPECT(!r.ok && !r.changed && !strcmp(r.code,"constructor_mismatch"));
    EXPECT(allocations==1 && destroys==1 && releases==1 && appends==0 && observes==0);
    EXPECT(get32(side_a+0x434)==0 && get32(model+0x7354)==1 && getp(temporary_data)==enemy);
    reset();constructor_contract=1;r=ceb_join(&engine,model,72,99);
    EXPECT(!r.ok && r.fatal && !r.changed && !strcmp(r.code,"constructor_contract"));
    EXPECT(allocations==1 && destroys==0 && releases==0 && appends==0 && observes==0);
    reset();ownership_fail=1;r=ceb_join(&engine,model,72,99);
    EXPECT(!r.ok && r.fatal && !r.changed && !strcmp(r.code,"ownership_mismatch"));
    EXPECT(allocations==1 && observes==1 && appends==1 && initializes==0);
}
static void verification_failures(void) {
    int mode;CebResult r;
    for(mode=1;mode<=3;++mode) {
        reset();initialize_tamper=mode;r=ceb_join(&engine,model,72,99);
        EXPECT(!r.ok && r.fatal && r.changed && !strcmp(r.code,"verification_failed"));
        EXPECT(allocations==1 && appends==1 && initializes==1);
        EXPECT(*(unsigned char *)(pending+0x2b7)==0);
        EXPECT(destroys==0 && releases==0);
    }
}
static void model_resolution(void) {
    CebPtr ud,object,decoy;int how;
    /* userdata holds a pointer to an interface object whose first field is the model */
    reset();ud=reserve(16);object=reserve(16);putp(ud,object);putp(object,model);
    EXPECT(ceb_resolve_model(&engine,ud,16,&how)==model && how==0x100);
    /* model stored inline in the userdata, after an unrelated header qword */
    reset();ud=reserve(24);decoy=reserve(8);putp(ud,decoy);putp(ud+8,model);
    EXPECT(ceb_resolve_model(&engine,ud,24,&how)==model && how==8);
    /* pointer to the object at +8 (e.g. after a type tag) */
    reset();ud=reserve(16);object=reserve(8);put32(ud,7);putp(ud+8,object);putp(object,model);
    EXPECT(ceb_resolve_model(&engine,ud,16,&how)==model && how==0x108);
    /* no back-pointer from the pending battle: refuse */
    reset();ud=reserve(16);object=reserve(16);putp(ud,object);putp(object,model);putp(pending+0xd0,0);
    EXPECT(ceb_resolve_model(&engine,ud,16,&how)==0 && how==-1);
    /* no pending battle */
    reset();ud=reserve(8);putp(ud,model);putp(model+0x6cb8,0);
    EXPECT(ceb_resolve_model(&engine,ud,8,&how)==0);
    /* short, unreadable or garbage blocks never match or dereference outside the registry */
    reset();ud=reserve(8);putp(ud,(CebPtr)0x12345678);
    EXPECT(ceb_resolve_model(&engine,ud,8,&how)==0 && how==-1);
    EXPECT(ceb_resolve_model(&engine,ud,4,&how)==0);
    EXPECT(ceb_resolve_model(&engine,ud,64,&how)==0);
    EXPECT(ceb_resolve_model(&engine,(CebPtr)0x10,8,&how)==0);
    /* only the first 64 bytes are searched */
    reset();ud=reserve(80);putp(ud+64,model);
    EXPECT(ceb_resolve_model(&engine,ud,80,&how)==0);
    EXPECT(ceb_model_matches(&engine,model) && !ceb_model_matches(&engine,pending));
}
static void make_ally_own_faction(void) { putp(getp(ally+0x128)+0x10,host_faction); }
static void same_faction_mode(void) {
    CebResult r;
    /* co-op mode never accepts the host's own faction */
    reset();make_ally_own_faction();
    expect_code(ceb_inspect(&engine,model,72,99),"not_two_humans");
    expect_code(ceb_join(&engine,model,72,99),"not_two_humans");
    EXPECT(allocations==0);
    /* single-player mode never accepts another faction */
    reset();expect_code(ceb_inspect_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH),"not_same_human_faction");
    reset();expect_code(ceb_join_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH),"not_same_human_faction");
    EXPECT(allocations==0);
    reset();make_ally_own_faction();expect_code(ceb_inspect_ex(&engine,model,72,99,8),"invalid_flags");
    /* non-human own faction refused */
    reset();make_ally_own_faction();*(unsigned char *)(host_faction+0x1bc4)=2;
    expect_code(ceb_join_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH),"not_same_human_faction");
    EXPECT(allocations==0);
    /* single player: the player's own faction is the local human (type 0) */
    reset();make_ally_own_faction();*(unsigned char *)(host_faction+0x1bc4)=0;
    r=ceb_inspect_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH);EXPECT(r.ok && !strcmp(r.code,"ready"));
    /* same-faction army: attached to the host cohort (separate same-faction cohorts are refused) */
    reset();make_ally_own_faction();
    r=ceb_inspect_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH);EXPECT(r.ok && !r.changed && !strcmp(r.code,"ready"));
    EXPECT(allocations==0 && appends==0);
    r=ceb_join_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH);
    EXPECT(r.ok && r.changed && !strcmp(r.code,"attached") && r.participants_after==r.participants_before+1);
    EXPECT(allocations==0 && appends==0 && pushes==1 && initializes==1 && *(unsigned char *)(pending+0x2b7)==1);
    r=ceb_join_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH);
    EXPECT(r.ok && !strcmp(r.code,"already_joined") && pushes==1);
    reset();make_ally_own_faction();expect_code(ceb_join_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION),"invalid_flags");
    EXPECT(allocations==0 && makes==0);
}
static void attach_mode(void) {
    CebResult r;const uint32_t A=CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH;
    reset();make_ally_own_faction();expect_code(ceb_inspect_ex(&engine,model,72,99,CEB_FLAG_ATTACH),"invalid_flags");
    reset();expect_code(ceb_join_ex(&engine,model,72,99,A),"not_same_human_faction");EXPECT(makes==0);
    reset();make_ally_own_faction();r=ceb_inspect_ex(&engine,model,72,99,A);EXPECT(r.ok && !r.changed && !strcmp(r.code,"ready"));
    EXPECT(makes==0 && pushes==0);
    r=ceb_join_ex(&engine,model,72,99,A);
    EXPECT(r.ok && r.changed && !r.fatal && !strcmp(r.code,"attached") && r.participants_after==r.participants_before+1);
    EXPECT(makes==1 && pushes==1 && entry_destroys==1 && prepares==1 && observes==1 && initializes==1);
    EXPECT(initialized_cohort==side_a+8 && allocations==0 && appends==0 && *(unsigned char *)(pending+0x2b7)==1);
    EXPECT(observed_subject==ally+0x38 && observed_listener==pending && directions==1 && direction_general==ally_general);
    r=ceb_join_ex(&engine,model,72,99,A);EXPECT(r.ok && !strcmp(r.code,"already_joined") && makes==1);
    /* entry that does not keep the force: destroyed, nothing appended */
    reset();make_ally_own_faction();make_mismatch=1;r=ceb_join_ex(&engine,model,72,99,A);
    EXPECT(!r.ok && !r.changed && !strcmp(r.code,"constructor_mismatch") && pushes==0 && entry_destroys==1 && prepares==0);
    /* append that does not land: fatal, reload required */
    reset();make_ally_own_faction();push_fail=1;r=ceb_join_ex(&engine,model,72,99,A);
    EXPECT(!r.ok && r.changed && r.fatal && !strcmp(r.code,"verification_failed") && initializes==0);
    EXPECT(*(unsigned char *)(pending+0x2b7)==0);
    /* invalid direction: nothing built */
    reset();make_ally_own_faction();direction_mode=1;expect_code(ceb_join_ex(&engine,model,72,99,A),"bad_direction");EXPECT(makes==0);
    /* initializer tampering is detected */
    reset();make_ally_own_faction();initialize_tamper=2;r=ceb_join_ex(&engine,model,72,99,A);
    EXPECT(!r.ok && r.fatal && !strcmp(r.code,"verification_failed"));
}
static void other_faction_test_mode(void) {
    CebResult r;const uint32_t T=CEB_FLAG_OTHER_FACTION_TEST;
    /* AI ally (type 2) at war: accepted only in the test mode, in its own cohort like co-op */
    reset();*(unsigned char *)(ally_faction+0x1bc4)=2;hostile=1;
    expect_code(ceb_join(&engine,model,72,99),"not_two_humans");
    r=ceb_join_ex(&engine,model,72,99,T);
    EXPECT(r.ok && r.changed && !strcmp(r.code,"joined") && allocations==1 && appends==1 && pushes==0);
    /* other faction never attached to the host cohort (crashes the engine), never co-op attach */
    reset();expect_code(ceb_join_ex(&engine,model,72,99,T|CEB_FLAG_ATTACH),"invalid_flags");
    reset();expect_code(ceb_join_ex(&engine,model,72,99,CEB_FLAG_ATTACH),"invalid_flags");EXPECT(makes==0 && allocations==0);
    /* never the host's own faction, never an AI host */
    reset();make_ally_own_faction();expect_code(ceb_join_ex(&engine,model,72,99,T),"not_other_faction");EXPECT(allocations==0);
    reset();*(unsigned char *)(host_faction+0x1bc4)=2;expect_code(ceb_join_ex(&engine,model,72,99,T),"not_other_faction");
    reset();expect_code(ceb_inspect_ex(&engine,model,72,99,CEB_FLAG_SAME_FACTION|CEB_FLAG_OTHER_FACTION_TEST),"invalid_flags");
}
int main(void) {
    validation_cases();successful_join();mutation_failures();verification_failures();model_resolution();same_faction_mode();attach_mode();other_faction_test_mode();
    while(block_count) free(blocks[--block_count].p);
    printf("bridge_core: %u checks, %u failures\n",checks,failures);
    return failures?1:0;
}
