/* bench/embed — embedding-boundary benchmark, Lua C API.
 *
 * The same operations/guest programs as bench_mahina.c, through the Lua C
 * API. Compiles unchanged against BOTH LuaJIT (5.1-era API) and Lua 5.4 —
 * the shims below cover the differences. Built twice by run.py, once per
 * engine.
 *
 * Fairness notes (mirroring bench_mahina.c's choices):
 *   - The called guest function, the table, and the string key are kept as
 *     C-stack slots / registry refs and reused per iteration — the Lua
 *     analogue of mahina's reused mh_values (no per-iteration global
 *     lookup or string re-intern in either host).
 *   - Calls go through lua_pcall (the protected entry), matching mahina's
 *     always-protected mh_call/mh_eval.
 *   - table get/set use lua_gettable/lua_settable (metamethod-aware),
 *     matching mh_table_get/mh_table_set.
 */
#include <string.h>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include "bench_common.h"
#include "sources.h"

#ifndef LUA_OK /* LuaJIT (Lua 5.1 API) */
#define LUA_OK 0
#endif

static int host_id_cb(lua_State *L) {
    lua_pushinteger(L, lua_tointeger(L, 1));
    return 1;
}

static void check(int st, lua_State *L, const char *op) {
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL %s: status %d: %s\n", op, st, lua_tostring(L, -1));
        exit(1);
    }
}

static void run_string(lua_State *L, const char *src, int nresults, const char *op) {
    check(luaL_loadbuffer(L, src, strlen(src), op), L, op);
    check(lua_pcall(L, 0, nresults, 0), L, op);
}

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) FAIL("init", "luaL_newstate");
    luaL_openlibs(L);

    uint64_t t0;
    long long sum;

    /* ---- host -> guest call ------------------------------------------- */
    run_string(L, SRC_ID_FN, 0, "call-setup");
    lua_getglobal(L, "id");
    int id_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    /* warmup */
    lua_rawgeti(L, LUA_REGISTRYINDEX, id_ref);
    lua_pushinteger(L, 1);
    check(lua_pcall(L, 1, 1, 0), L, "call");
    lua_pop(L, 1);
    sum = 0;
    t0 = now_ns();
    for (long long i = 0; i < N_CALL; i++) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, id_ref);
        lua_pushinteger(L, (lua_Integer)i);
        check(lua_pcall(L, 1, 1, 0), L, "call");
        if (!lua_isnumber(L, -1)) FAIL("call", "non-int result");
        sum += (long long)lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
    report("call", now_ns() - t0, N_CALL, sum);

    /* ---- guest -> host callback --------------------------------------- */
    lua_pushcfunction(L, host_id_cb);
    lua_setglobal(L, "host_id");
    run_string(L, SRC_CALLBACK_LOOP, 1, "callback"); /* warmup */
    lua_pop(L, 1);
    t0 = now_ns();
    run_string(L, SRC_CALLBACK_LOOP, 1, "callback");
    uint64_t cb_elapsed = now_ns() - t0;
    if ((long long)lua_tointeger(L, -1) != CALLBACK_CHECKSUM) FAIL("callback", "bad checksum");
    report("callback", cb_elapsed, N_CALLBACK, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* ---- table get / set (reused guest-string key) --------------------- */
    lua_newtable(L);
    int tbl = lua_gettop(L);
    lua_pushlstring(L, TABLE_KEY, strlen(TABLE_KEY));
    int kidx = lua_gettop(L);
    lua_pushvalue(L, kidx);
    lua_pushinteger(L, 42);
    lua_settable(L, tbl);

    sum = 0;
    t0 = now_ns();
    for (long long i = 0; i < N_TABLE; i++) {
        lua_pushvalue(L, kidx);
        lua_gettable(L, tbl);
        if (!lua_isnumber(L, -1)) FAIL("table_get", "non-int");
        sum += (long long)lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
    report("table_get", now_ns() - t0, N_TABLE, sum);

    t0 = now_ns();
    for (long long i = 0; i < N_TABLE; i++) {
        lua_pushvalue(L, kidx);
        lua_pushinteger(L, (lua_Integer)i);
        lua_settable(L, tbl);
    }
    lua_pushvalue(L, kidx);
    lua_gettable(L, tbl);
    report("table_set", now_ns() - t0, N_TABLE, (long long)lua_tointeger(L, -1));
    lua_pop(L, 3); /* value, key, table */

    /* ---- iteration over a hash-heavy table ------------------------------ */
    run_string(L, SRC_BUILD_BIG, 0, "iter-setup");
    lua_getglobal(L, "big");
    int big = lua_gettop(L);
    sum = 0;
    t0 = now_ns();
    for (int pass = 0; pass < N_ITER_PASSES; pass++) {
        lua_pushnil(L);
        while (lua_next(L, big) != 0) {
            if (!lua_isnumber(L, -1)) FAIL("iterate", "non-int value");
            sum += (long long)lua_tointeger(L, -1);
            lua_pop(L, 1); /* keep key for the next lua_next */
        }
    }
    report("iterate", now_ns() - t0, (long long)N_ITER_PASSES * BIG_ENTRIES, sum);
    lua_pop(L, 1); /* big */

    /* ---- ref churn ------------------------------------------------------ */
    t0 = now_ns();
    for (long long i = 0; i < N_REF; i++) {
        lua_pushlstring(L, REF_STRING, strlen(REF_STRING));
        int r = luaL_ref(L, LUA_REGISTRYINDEX);
        luaL_unref(L, LUA_REGISTRYINDEX, r);
    }
    report("ref", now_ns() - t0, N_REF, N_REF);

    /* ---- repeated compilation ------------------------------------------- */
    t0 = now_ns();
    for (long long i = 0; i < N_COMPILE; i++) {
        check(luaL_loadbuffer(L, SRC_SMALL_CHUNK, strlen(SRC_SMALL_CHUNK), "recompile"), L,
              "compile");
        lua_pop(L, 1);
    }
    report("compile", now_ns() - t0, N_COMPILE, N_COMPILE);

    /* ---- eval round trip ------------------------------------------------ */
    sum = 0;
    t0 = now_ns();
    for (long long i = 0; i < N_EVAL; i++) {
        run_string(L, SRC_EVAL, 1, "eval");
        sum += (long long)lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
    report("eval", now_ns() - t0, N_EVAL, sum);

    report_maxrss();
    lua_close(L);
    return 0;
}
