/* In-process Lua 5.1 bridge for one exact game build. No code patches, injected
 * threads, DllMain work, proxy DLLs or copies of campaign units. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "bridge_core.h"
#include "native_profile.h"
#pragma comment(lib,"bcrypt.lib")

typedef struct lua_State lua_State;
typedef int (__cdecl *LuaFunction)(lua_State *);
static void (__cdecl *l_create)(lua_State *,int,int);
static void (__cdecl *l_string)(lua_State *,const char *);
static void (__cdecl *l_bool)(lua_State *,int);
/* Warhammer III builds Lua with lua_Number = float: lua_tonumber returns it in xmm0 with movss
 * and lua_pushnumber reads xmm1 with movss (checked in the analyzed exe). */
static void (__cdecl *l_number)(lua_State *,float);
static void (__cdecl *l_closure)(lua_State *,LuaFunction,int);
static void (__cdecl *l_field)(lua_State *,int,const char *);
static int (__cdecl *l_type)(lua_State *,int);
static size_t (__cdecl *l_length)(lua_State *,int);
static void *(__cdecl *l_userdata)(lua_State *,int);
static float (__cdecl *l_to_number)(lua_State *,int);
static int supported,initialized,disabled;
static CebEngine engine;
static DWORD campaign_thread;
static const char *profile_reason="Module not initialized";
static char actual_hash[65];

/* 1.1.6. The campaign UI object (0x3570 bytes, built by 0x141e53660) is stored as ui+0x30 in the
 * global 0x143f74188. Its listener at ui+0x538 (vtable 0x143a534d0, handler 0x141ecb0c4) opens the
 * battle results when the model announces them, only if ui+0x3360 == 0 (UI ready) and
 * 0x1426e941c(pending, local faction) holds: pending+0xd8 in 7..12, pending+0x29d != 0 and the local
 * faction listed in pending+0x178 (0x18-byte entries, faction first). ui+0x2f60 is the local context:
 * +0x90 model, +0x1c8 local faction. */
#define CEB_CAMPAIGN_UI_GLOBAL_RVA 0x3f74188u
#define CEB_RESULTS_LISTENER_VTABLE_RVA 0x3a534d0u
#define CEB_RESULTS_HANDLER_RVA 0x1ecb0c4u
static CebPtr campaign_ui_global,results_listener_vtable,open_results_entry,rebuild_choosers_entry,open_pre_battle_entry;
static int readable(CebPtr address,size_t n);
static int read_ptr(CebPtr p,CebPtr *out) {*out=0;if(!readable(p,8)) return 0;memcpy(out,(void *)p,8);return 1;}
static int readable(CebPtr address,size_t n) {
    MEMORY_BASIC_INFORMATION info;CebPtr end,next;
    if(address<0x10000 || n>0x1000000 || address>UINTPTR_MAX-n) return 0;
    end=address+n;
    while(address<end) {
        if(!VirtualQuery((void *)address,&info,sizeof(info)) || info.State!=MEM_COMMIT ||
           (info.Protect&(PAGE_GUARD|PAGE_NOACCESS)) || !info.Protect) return 0;
        next=(CebPtr)info.BaseAddress+info.RegionSize;
        if(next<=address) return 0;
        address=next;
    }
    return 1;
}
static int hash_file(const wchar_t *path,char output[65]) {
    BCRYPT_ALG_HANDLE algorithm=NULL;BCRYPT_HASH_HANDLE hash=NULL;
    HANDLE file=INVALID_HANDLE_VALUE;unsigned char buffer[65536],digest[32];
    DWORD got=0;int ok=0;size_t i;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0) goto done;
    if(BCryptCreateHash(algorithm,&hash,NULL,0,NULL,0,0)<0) goto done;
    file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,NULL);
    if(file==INVALID_HANDLE_VALUE) goto done;
    for(;;) {
        if(!ReadFile(file,buffer,sizeof(buffer),&got,NULL)) goto done;
        if(!got) break;
        if(BCryptHashData(hash,buffer,got,0)<0) goto done;
    }
    if(BCryptFinishHash(hash,digest,sizeof(digest),0)<0) goto done;
    for(i=0;i<32;++i) sprintf_s(output+i*2,3,"%02x",digest[i]);
    output[64]=0;ok=1;
done:
    if(file!=INVALID_HANDLE_VALUE) CloseHandle(file);
    if(hash) BCryptDestroyHash(hash);
    if(algorithm) BCryptCloseAlgorithmProvider(algorithm,0);
    return ok;
}
static int bind_lua(HMODULE module) {
#define LUA_BIND(variable,name) *(FARPROC *)&variable=GetProcAddress(module,name)
    LUA_BIND(l_create,"lua_createtable");LUA_BIND(l_string,"lua_pushstring");
    LUA_BIND(l_bool,"lua_pushboolean");LUA_BIND(l_number,"lua_pushnumber");
    LUA_BIND(l_closure,"lua_pushcclosure");LUA_BIND(l_field,"lua_setfield");
    LUA_BIND(l_type,"lua_type");LUA_BIND(l_length,"lua_objlen");
    LUA_BIND(l_userdata,"lua_touserdata");LUA_BIND(l_to_number,"lua_tonumber");
#undef LUA_BIND
    return l_create&&l_string&&l_bool&&l_number&&l_closure&&l_field&&l_type&&l_length&&l_userdata&&l_to_number;
}
static int verify_profile(HMODULE module) {
    wchar_t path[32768];const IMAGE_DOS_HEADER *dos=(void *)module;const IMAGE_NT_HEADERS64 *nt;
    size_t i;DWORD count=GetModuleFileNameW(module,path,32768);
    if(!count || count>=32768 || dos->e_magic!=IMAGE_DOS_SIGNATURE) {profile_reason="Invalid host image";return 0;}
    nt=(void *)((unsigned char *)module+dos->e_lfanew);
    if(nt->Signature!=IMAGE_NT_SIGNATURE || nt->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64 ||
       nt->OptionalHeader.SizeOfImage!=CEB_EXPECTED_IMAGE_SIZE || nt->FileHeader.TimeDateStamp!=CEB_EXPECTED_TIMESTAMP) {
        profile_reason="Unsupported executable build";return 0;
    }
    if(!hash_file(path,actual_hash) || strcmp(actual_hash,CEB_EXPECTED_SHA256)) {profile_reason="Executable SHA-256 differs from analyzed build";return 0;}
    for(i=0;i<sizeof(ceb_signatures)/sizeof(ceb_signatures[0]);++i) {
        if(memcmp((unsigned char *)module+ceb_signatures[i].rva,ceb_signatures[i].bytes,24)) {
            profile_reason="Native entry signature mismatch";return 0;
        }
    }
    /* Function pointer representations are identical on this Windows x64 target. */
#define ENGINE_BIND(field,index) do { CebPtr p=(CebPtr)module+ceb_signatures[index].rva; memcpy(&engine.field,&p,sizeof(p)); } while(0)
    ENGINE_BIND(allocate,0);ENGINE_BIND(release,1);ENGINE_BIND(destroy_cohort,2);
    ENGINE_BIND(construct_cohort,3);ENGINE_BIND(append_cohort,4);ENGINE_BIND(prepare_character,5);
    ENGINE_BIND(observe_force,6);ENGINE_BIND(initialize_cohort,7);ENGINE_BIND(lookup_force,8);ENGINE_BIND(at_war,9);
    ENGINE_BIND(reinforcement_direction,10);
    ENGINE_BIND(make_force_data,11);ENGINE_BIND(push_force_data,12);ENGINE_BIND(destroy_force_data,13);
#undef ENGINE_BIND
    {   /* 1.1.6 battle results (see results below). Signature 15 is 'mov [rip+disp32], rcx'. */
        CebPtr store=(CebPtr)module+ceb_signatures[15].rva,slot=0;int32_t disp;
        memcpy(&disp,(void *)(store+3),4);
        campaign_ui_global=store+7+(CebPtr)(intptr_t)disp;
        results_listener_vtable=(CebPtr)module+CEB_RESULTS_LISTENER_VTABLE_RVA;
        open_results_entry=(CebPtr)module+ceb_signatures[14].rva;
        rebuild_choosers_entry=(CebPtr)module+ceb_signatures[16].rva;
        open_pre_battle_entry=(CebPtr)module+ceb_signatures[17].rva;
        if(readable(results_listener_vtable+8,8)) memcpy(&slot,(void *)(results_listener_vtable+8),8);
        if(campaign_ui_global!=(CebPtr)module+CEB_CAMPAIGN_UI_GLOBAL_RVA || slot!=(CebPtr)module+CEB_RESULTS_HANDLER_RVA) {
            profile_reason="Campaign UI layout differs from analyzed build";return 0;
        }
    }
    engine.readable=readable;profile_reason="Exact executable and native signatures verified";return 1;
}
static char diag[1400];
static char model_source[32]="none";
static void string_field(lua_State *L,const char *key,const char *value) {l_string(L,value);l_field(L,-2,key);}
static void bool_field(lua_State *L,const char *key,int value) {l_bool(L,value);l_field(L,-2,key);}
static void number_field(lua_State *L,const char *key,uint32_t value) {l_number(L,(float)value);l_field(L,-2,key);}
static void log_result(const char *operation,const CebResult *r) {
    FILE *f=NULL;
    if(fopen_s(&f,"coop_event_battles_native_log.txt","a") || !f) return;
    fprintf(f,"%s version=%s model_source=%s ok=%d changed=%d fatal=%d code=%s host_force=%u ally_force=%u participants=%u->%u detail=%s\n",
        operation,CEB_BRIDGE_VERSION,model_source,r->ok,r->changed,r->fatal,r->code,r->host_force_cqi,r->ally_force_cqi,
        r->participants_before,r->participants_after,r->detail);fclose(f);
}
static int status(lua_State *L) {
    l_create(L,0,7);bool_field(L,"supported",supported&&!disabled);
    string_field(L,"version",CEB_BRIDGE_VERSION);number_field(L,"protocol",CEB_BRIDGE_PROTOCOL);
    string_field(L,"reason",disabled?"Native bridge disabled after an exception; reload required":profile_reason);
    string_field(L,"exe_sha256",actual_hash);bool_field(L,"code_patches",0);bool_field(L,"fatal",disabled);return 1;
}
static void describe_block(CebPtr block,size_t length,int type) {
    size_t i,n=length<64?length:64,used;CebPtr q,d;
    used=(size_t)snprintf(diag,sizeof(diag),"Campaign model not found in the game interface (Lua type %d, %u bytes):",type,(unsigned)length);
    if(n<8 || !readable(block,n)) {snprintf(diag+used,sizeof(diag)-used," block unreadable");return;}
    for(i=0;i+8<=n && used<sizeof(diag)-80;i+=8) {
        memcpy(&q,(void *)(block+i),8);
        if(readable(q,8)) {memcpy(&d,(void *)q,8);used+=(size_t)snprintf(diag+used,sizeof(diag)-used," +%u=%llx->%llx",(unsigned)i,(unsigned long long)q,(unsigned long long)d);}
        else used+=(size_t)snprintf(diag+used,sizeof(diag)-used," +%u=%llx",(unsigned)i,(unsigned long long)q);
    }
}
static CebResult execute(lua_State *L,int mutate) {
    CebResult r;void *raw;CebPtr model;double host,ally;int type,how,t4;size_t length;uint32_t flags=0;
    memset(&r,0,sizeof(r));r.code="invalid_arguments";r.detail="Expected campaign interface and two integer military-force CQIs";
    snprintf(model_source,sizeof(model_source),"none");
    if(!supported || disabled) {r.code="unsupported_host";r.detail=profile_reason;r.fatal=disabled;return r;}
    if(GetCurrentThreadId()!=campaign_thread) {r.code="wrong_thread";r.detail="Native campaign calls must run on the loading Lua thread";return r;}
    type=l_type(L,1);
    if((type!=7 && type!=2) || l_type(L,2)!=3 || l_type(L,3)!=3) {
        snprintf(diag,sizeof(diag),"Expected userdata and two numbers; got Lua types %d, %d, %d",type,l_type(L,2),l_type(L,3));
        r.detail=diag;return r;
    }
    /* Optional 4th argument: join mode flags (number). Absent or nil means 0 (co-op). */
    t4=l_type(L,4);
    if(t4==3) {
        double f=(double)l_to_number(L,4);
        if(f!=0.0 && f!=(double)(CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH) && f!=(double)CEB_FLAG_OTHER_FACTION_TEST
#ifdef CEB_TEST_BUILD
           && f!=(double)(CEB_FLAG_ATTACH|CEB_FLAG_OTHER_FACTION_TEST)
           && f!=(double)(CEB_FLAG_OTHER_FACTION_TEST|CEB_FLAG_TEST_DEPLOY_AT_START)
#endif
           ) {snprintf(diag,sizeof(diag),"Invalid join mode %.3f",f);r.detail=diag;return r;}
        flags=(uint32_t)f;
    } else if(t4!=0 && t4!=-1) {snprintf(diag,sizeof(diag),"Join mode must be a number; got Lua type %d",t4);r.detail=diag;return r;}
    raw=l_userdata(L,1);host=(double)l_to_number(L,2);ally=(double)l_to_number(L,3);
    length=type==7?l_length(L,1):64;
    /* A float holds every integer up to 2^24 exactly; command queue indices are far below that. */
    if(!raw || !isfinite(host) || !isfinite(ally) || host<1 || host>16777216.0 || ally<1 || ally>16777216.0 || host!=(double)(uint32_t)host || ally!=(double)(uint32_t)ally) {
        snprintf(diag,sizeof(diag),"Invalid arguments: userdata=%p host_force=%.3f ally_force=%.3f",raw,host,ally);
        r.detail=diag;return r;
    }
    __try {
        model=ceb_resolve_model(&engine,(CebPtr)raw,length,&how);
        if(!model) {
            describe_block((CebPtr)raw,length,type);
            r.code="model_not_found";r.detail=diag;r.host_force_cqi=(uint32_t)host;r.ally_force_cqi=(uint32_t)ally;
        } else {
            snprintf(model_source,sizeof(model_source),how>=0x100?"*(userdata+%d)":"userdata+%d",how&0xff);
            r=mutate?ceb_join_ex(&engine,model,(uint32_t)host,(uint32_t)ally,flags):ceb_inspect_ex(&engine,model,(uint32_t)host,(uint32_t)ally,flags);
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        memset(&r,0,sizeof(r));r.code="native_exception";
        r.detail=mutate?"Exception during native operation; stop and reload the pre-test save":"Exception during read-only inspection; no join attempted";
        r.fatal=1;disabled=1;
    }
    if(r.fatal) disabled=1;
    return r;
}
static int result_table(lua_State *L,const char *operation,CebResult r) {
    log_result(operation,&r);l_create(L,0,11);
    bool_field(L,"ok",r.ok);bool_field(L,"changed",r.changed);bool_field(L,"fatal",r.fatal);
    string_field(L,"code",r.code);string_field(L,"detail",r.detail);
    number_field(L,"host_force_cqi",r.host_force_cqi);number_field(L,"ally_force_cqi",r.ally_force_cqi);
    number_field(L,"participants_before",r.participants_before);number_field(L,"participants_after",r.participants_after);
    string_field(L,"version",CEB_BRIDGE_VERSION);string_field(L,"model_source",model_source);return 1;
}
#ifdef CEB_TEST_BUILD
/* Test builds only, read-only: dump(game_interface, tag) writes every cohort of the pending battle
 * (both sides: primary at side+8 and secondaries at side+0x438, 0x428 bytes each, plus their 0x98
 * army entries) and the pending battle itself (0x2d0 bytes) to ceb_cohort_dump.txt, to compare a
 * cohort that deploys at the start with one that arrives as a reinforcement. */
static FILE *dump_file;
static int dump_ptr(CebPtr p,CebPtr *out) { if(!readable(p,8)) return 0; memcpy(out,(void *)p,8); return 1; }
static uint32_t dump_u32(CebPtr p) { uint32_t v=0; if(readable(p,4)) memcpy(&v,(void *)p,4); return v; }
static void dump_bytes(const char *label,CebPtr p,size_t n) {
    size_t i;
    fprintf(dump_file,"%s @%llx size %zx\n",label,(unsigned long long)p,n);
    if(!readable(p,n)) {fprintf(dump_file,"  (unreadable)\n");return;}
    for(i=0;i<n;i+=16) {
        size_t j;fprintf(dump_file,"  %04zx:",i);
        for(j=0;j<16 && i+j<n;++j) fprintf(dump_file," %02x",((unsigned char *)p)[i+j]);
        fprintf(dump_file,"\n");
    }
}
static void dump_cohort(const char *label,CebPtr c) {
    CebPtr force=0,entries=0;uint32_t n,i;char name[96];
    dump_ptr(c+0x370,&force);
    fprintf(dump_file,"%s cohort @%llx force @%llx force_cqi %u faction_key_ptr(+8) %llx entries %u\n",label,
        (unsigned long long)c,(unsigned long long)force,force?dump_u32(force+8):0,
        (unsigned long long)(readable(c+8,8)?*(CebPtr *)(c+8):0),dump_u32(c+0x414));
    dump_bytes("  cohort",c,0x428);
    n=dump_u32(c+0x414);dump_ptr(c+0x418,&entries);
    for(i=0;i<n && i<64 && entries;++i) {
        CebPtr ef=0;dump_ptr(entries+(CebPtr)i*0x98,&ef);
        snprintf(name,sizeof(name),"  entry %u force_cqi %u",i,ef?dump_u32(ef+8):0);
        dump_bytes(name,entries+(CebPtr)i*0x98,0x98);
    }
}
static int dump(lua_State *L) {
    void *raw;int how=0,type=l_type(L,1);size_t length;CebPtr model,pending=0;int tag=0;
    const char *result="ok";
    if(l_type(L,2)==3) tag=(int)l_to_number(L,2); /* 1 = pending battle seen, 2 = after a join */
    raw=l_userdata(L,1);length=type==7?l_length(L,1):64;
    if(!raw) {l_string(L,"no userdata");return 1;}
    if(fopen_s(&dump_file,"ceb_cohort_dump.txt","a") || !dump_file) {l_string(L,"cannot open dump file");return 1;}
    __try {
        model=ceb_resolve_model(&engine,(CebPtr)raw,length,&how);
        fprintf(dump_file,"==== DUMP tag %d model %llx\n",tag,(unsigned long long)model);
        if(model && dump_ptr(model+0x6cb8,&pending) && pending) {
            int s;
            fprintf(dump_file,"pending @%llx +d8=%u set_piece(+278)=%llx\n",(unsigned long long)pending,dump_u32(pending+0xd8),
                (unsigned long long)(readable(pending+0x278,8)?*(CebPtr *)(pending+0x278):0));
            dump_bytes("pending",pending,0x2d0);
            for(s=0;s<2;++s) {
                CebPtr side=0,list=0;uint32_t n,i;char label[64];
                dump_ptr(pending+(s?0xf8:0xf0),&side);
                fprintf(dump_file,"-- side %s @%llx secondaries %u\n",s?"0xf8":"0xf0",(unsigned long long)side,side?dump_u32(side+0x434):0);
                if(!side) continue;
                dump_bytes("  side header",side,0x10);
                dump_bytes("  side tail",side+0x430,0x18);
                snprintf(label,sizeof(label),"side %d primary",s);dump_cohort(label,side+8);
                n=dump_u32(side+0x434);dump_ptr(side+0x438,&list);
                for(i=0;i<n && i<32 && list;++i) {
                    CebPtr c=0;dump_ptr(list+(CebPtr)i*8,&c);
                    snprintf(label,sizeof(label),"side %d secondary %u",s,i);
                    if(c) dump_cohort(label,c);
                }
            }
        } else {fprintf(dump_file,"no pending battle\n");result="no pending battle";}
    } __except(EXCEPTION_EXECUTE_HANDLER) {result="exception while dumping";fprintf(dump_file,"EXCEPTION\n");}
    fclose(dump_file);dump_file=NULL;
    l_string(L,result);return 1;
}
#endif
/* results(mode): mode 0 only reads, 1 opens the panel when the game's conditions hold, 2 also rebuilds
 * the chooser list first when the local faction owns a cohort of the pending battle but is missing
 * from it. The ally's client never opened popup_battle_results after an autoresolve of a mission
 * battle it joined, and the host waited forever. 1.1.6 test: on the ally's client state=8,
 * results_ready=1, but the chooser list pending+0x178 had 1 entry and not the local faction, while
 * the wait set pending+0x118 had 2. The list is per client: 0x1426c0940 skips remote humans
 * (faction+0x1bc4 == 1) and otherwise looks for the faction among the cohorts of both sides
 * (0x1426c0980: side+0x10, then +8 of each cohort in side+0x438). Mode 2 rebuilds it with the game's
 * own 0x142910fa8(pending+0x178), the call 0x1426d1f24 and 0x1426b2eac make. */
static size_t dump_side(char *out,size_t size,const char *label,CebPtr side,CebPtr local,int *found) {
    size_t used=0;uint32_t n=0,i;CebPtr primary=0,list=0;
    if(!side || !readable(side,0x440)) return (size_t)snprintf(out,size," %s=none",label);
    primary=*(CebPtr *)(side+0x10);n=*(uint32_t *)(side+0x434);list=*(CebPtr *)(side+0x438);
    if(primary==local) *found=1;
    used=(size_t)snprintf(out,size," %s[primary=%llx sec=%u:",label,(unsigned long long)primary,n);
    for(i=0;i<n && i<12 && used<size-40;++i) {
        CebPtr c=0,fp=0;
        if(read_ptr(list+(CebPtr)i*8,&c) && c) read_ptr(c+8,&fp);
        if(fp==local) *found=1;
        used+=(size_t)snprintf(out+used,size-used," %llx",(unsigned long long)fp);
    }
    if(used<size-2) used+=(size_t)snprintf(out+used,size-used,"]");
    return used;
}
/* 1.1.10: the chooser list feeds the battle setup. After 1.1.8 only the ally's client rebuilt it, so
 * the host listed 1 human and the ally 2, and a manual battle desynced at launch. Mode 2 now rebuilds
 * it on every client where a human who owns a cohort of the battle is missing, and mode 3 does only
 * that, without opening anything, so both PCs end with the same list. */
static int side_has(CebPtr side,CebPtr fp) {
    uint32_t n,i;CebPtr list;
    if(!side || !fp || !readable(side,0x440)) return 0;
    if(*(CebPtr *)(side+0x10)==fp) return 1;
    n=*(uint32_t *)(side+0x434);list=*(CebPtr *)(side+0x438);
    for(i=0;i<n && i<32;++i) {CebPtr c=0,f=0;if(read_ptr(list+(CebPtr)i*8,&c) && c && read_ptr(c+8,&f) && f==fp) return 1;}
    return 0;
}
static int chooser_listed(CebPtr pending,CebPtr fp) {
    uint32_t n=*(uint32_t *)(pending+0x17c),i;CebPtr e=*(CebPtr *)(pending+0x180);
    for(i=0;i<n && i<16;++i) {CebPtr f=0;if(read_ptr(e+(CebPtr)i*0x18,&f) && f==fp) return 1;}
    return 0;
}
/* prebattle(mode), 1.1.8: same checks and modes for popup_pre_battle, which the ally's client never
 * opened either: its army joined after PendingBattle, when its chooser list was already built. The
 * game's 0x141ea2fa4(ui) opens it when 0x1426e9474 holds (pending+0xd8 == 1 and the local faction
 * listed); the UI tick 0x141ec5c7c calls it the same way, with no other step. */
static int battle_panel(lua_State *L,int pre);
static int results(lua_State *L) {return battle_panel(L,0);}
static int prebattle(lua_State *L) {return battle_panel(L,1);}
static int battle_panel(lua_State *L,int pre) {
    char detail[1600];const char *code="unknown";int mode=0,opened=0,rebuilt=0;FILE *f=NULL;
    detail[0]=0;
    if(l_type(L,1)==3) {float m=l_to_number(L,1);if(m==1.0f) mode=1;else if(m==2.0f) mode=2;else if(m==3.0f) mode=3;}
    if(!supported || disabled) {code="unsupported_host";snprintf(detail,sizeof(detail),"%s",profile_reason);}
    else if(GetCurrentThreadId()!=campaign_thread) code="wrong_thread";
    else __try {
        CebPtr holder,ui,vt,ctx,model,local,pending,entries,world=0,humans=0;
        uint32_t state=0,count=0,i,listed=0,wait_count=0,human_count=0;uint8_t flag=0,ready=0;int in_battle=0;size_t used;
        if(!read_ptr(campaign_ui_global,&holder) || !holder) code="no_campaign_ui";
        else if(ui=holder-0x30,!read_ptr(ui+0x538,&vt) || vt!=results_listener_vtable) code="unexpected_campaign_ui";
        else if(!read_ptr(ui+0x2f60,&ctx) || !read_ptr(ctx+0x90,&model) || !read_ptr(ctx+0x1c8,&local) || !local ||
                !readable(local+0x1bc4,1) || !read_ptr(model+0x6cb8,&pending) || !pending || !readable(pending,0x2d0) ||
                !readable(ui+0x3360,1)) code="no_pending_battle";
        else {
            flag=*(uint8_t *)(ui+0x3360);state=*(uint32_t *)(pending+0xd8);ready=*(uint8_t *)(pending+0x29d);
            used=(size_t)snprintf(detail,sizeof(detail),"ui_wait=%u state=%u results_ready=%u local=%llx(%u)",
                flag,state,ready,(unsigned long long)local,*(uint8_t *)(local+0x1bc4));
            if(read_ptr(model+0x6ca0,&world) && world && readable(world+0x84,12)) {
                human_count=*(uint32_t *)(world+0x84);humans=*(CebPtr *)(world+0x88);
                used+=(size_t)snprintf(detail+used,sizeof(detail)-used," humans=%u:",human_count);
                for(i=0;i<human_count && i<8 && used<sizeof(detail)-60;++i) {
                    CebPtr h=0;read_ptr(humans+(CebPtr)i*8,&h);
                    used+=(size_t)snprintf(detail+used,sizeof(detail)-used," %llx(%u)",(unsigned long long)h,
                        (h && readable(h+0x1bc4,1))?*(uint8_t *)(h+0x1bc4):99);
                }
            }
            used+=dump_side(detail+used,sizeof(detail)-used,"f0",*(CebPtr *)(pending+0xf0),local,&in_battle);
            used+=dump_side(detail+used,sizeof(detail)-used,"f8",*(CebPtr *)(pending+0xf8),local,&in_battle);
            count=*(uint32_t *)(pending+0x17c);entries=*(CebPtr *)(pending+0x180);
            used+=(size_t)snprintf(detail+used,sizeof(detail)-used," choosers=%u:",count);
            for(i=0;i<count && i<8 && used<sizeof(detail)-40;++i) {
                CebPtr fp=0;read_ptr(entries+(CebPtr)i*0x18,&fp);if(fp==local) listed=1;
                used+=(size_t)snprintf(detail+used,sizeof(detail)-used," %llx",(unsigned long long)fp);
            }
            wait_count=*(uint32_t *)(pending+0x11c);
            used+=(size_t)snprintf(detail+used,sizeof(detail)-used," wait=%u/%u:",wait_count,*(uint32_t *)(pending+0x118));
            for(i=0;i<wait_count && i<8 && used<sizeof(detail)-80;++i) {
                CebPtr data=*(CebPtr *)(pending+0x120),a=0,b=0;
                read_ptr(data+(CebPtr)i*16,&a);read_ptr(data+(CebPtr)i*16+8,&b);
                used+=(size_t)snprintf(detail+used,sizeof(detail)-used," [%llx %llx]",(unsigned long long)a,(unsigned long long)b);
            }
            if(used<sizeof(detail)-40)
                used+=(size_t)snprintf(detail+used,sizeof(detail)-used," in_battle=%d flag29f=%u",in_battle,*(uint8_t *)(pending+0x29f));
            if(flag) code="ui_not_ready";
            else if(pre && state!=1) code="not_pre_battle";
            else if(!pre && (state<7 || state>12)) code="not_post_battle";
            else if(!pre && !ready) code="results_not_ready";
            else {
                int missing=(!listed && in_battle);
                if(world && humans) for(i=0;i<human_count && i<8;++i) {
                    CebPtr h=0;
                    if(read_ptr(humans+(CebPtr)i*8,&h) && h && (side_has(*(CebPtr *)(pending+0xf0),h) ||
                        side_has(*(CebPtr *)(pending+0xf8),h)) && !chooser_listed(pending,h)) missing=1;
                }
                if(missing && mode>=2) {
                    void (*rebuild)(CebPtr);memcpy(&rebuild,&rebuild_choosers_entry,sizeof(rebuild));
                    rebuild(pending+0x178);rebuilt=1;
                    count=*(uint32_t *)(pending+0x17c);entries=*(CebPtr *)(pending+0x180);
                    for(i=0;i<count && i<16;++i) {CebPtr fp;if(read_ptr(entries+(CebPtr)i*0x18,&fp) && fp==local) listed=1;}
                    if(used<sizeof(detail)-40) used+=(size_t)snprintf(detail+used,sizeof(detail)-used," rebuilt choosers=%u listed=%u",count,listed);
                }
                if(mode==3) code=rebuilt?"synced":"in_sync";
                else if(!listed) code=in_battle?"local_not_listed":"local_not_in_battle";
                else if(!mode) code="ready";
                else {
                    void (*opener)(CebPtr);memcpy(&opener,pre?&open_pre_battle_entry:&open_results_entry,sizeof(opener));
                    opener(ui);code="opened";opened=1;
                }
            }
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {code="native_exception";disabled=1;}
    if(!fopen_s(&f,"coop_event_battles_native_log.txt","a") && f) {
        fprintf(f,"%s version=%s mode=%d code=%s %s\n",pre?"prebattle":"results",CEB_BRIDGE_VERSION,mode,code,detail);fclose(f);
    }
    l_create(L,0,4);string_field(L,"code",code);string_field(L,"detail",detail);bool_field(L,"opened",opened);
    bool_field(L,"rebuilt",rebuilt);
    return 1;
}
static int inspect(lua_State *L) {return result_table(L,"inspect",execute(L,0));}
static int join(lua_State *L) {return result_table(L,"join",execute(L,1));}
__declspec(dllexport) unsigned int ceb_bridge_abi_version(void) {return CEB_BRIDGE_PROTOCOL;}
__declspec(dllexport) int ceb_bridge_host_supported(void) {
    HMODULE module=GetModuleHandleW(NULL);
    if(!initialized) {initialized=1;supported=bind_lua(module)&&verify_profile(module);}
    return supported&&!disabled;
}
__declspec(dllexport) int luaopen_ceb_native_bridge(lua_State *L) {
    HMODULE module=GetModuleHandleW(NULL);
    if(!L || !bind_lua(module)) return 0;
    if(!initialized) {initialized=1;supported=verify_profile(module);}
    if(!campaign_thread) campaign_thread=GetCurrentThreadId();
    l_create(L,0,4);l_closure(L,status,0);l_field(L,-2,"status");
    l_closure(L,inspect,0);l_field(L,-2,"inspect");l_closure(L,join,0);l_field(L,-2,"join");
    l_closure(L,results,0);l_field(L,-2,"results");
    l_closure(L,prebattle,0);l_field(L,-2,"prebattle");
#ifdef CEB_TEST_BUILD
    l_closure(L,dump,0);l_field(L,-2,"dump");
#endif
    string_field(L,"version",CEB_BRIDGE_VERSION);return 1;
}
