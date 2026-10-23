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
        if(f!=0.0 && f!=(double)(CEB_FLAG_SAME_FACTION|CEB_FLAG_ATTACH) && f!=(double)CEB_FLAG_OTHER_FACTION_TEST) {snprintf(diag,sizeof(diag),"Invalid join mode %.3f",f);r.detail=diag;return r;}
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
    string_field(L,"version",CEB_BRIDGE_VERSION);return 1;
}
