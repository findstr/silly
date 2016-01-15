#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include "lsha1.h"
#include "sha256.h"
#include "aes.h"

static int
lrandomkey(lua_State *L)
{
        int i;
        char buff[8];

        for (i = 0; i < 8; i++)
                buff[i] = random() % 26 + 'a';
        
        lua_pushlstring(L, buff, 8);

        return 1;
}

#define AESKEY_LEN      32
#define AESGROUP_LEN    16
#define AESIV           "!*^$~)_+=-)(87^$#Dfhjklmnb<>,k./;KJl"

static void 
aes_encode(uint8_t key[AESKEY_LEN], const uint8_t *src, uint8_t *dst, int sz)
{
        int i;
        int group;
        int last;
        uint8_t tail[AESGROUP_LEN];
        aes_context ctx;

        group = sz / AESGROUP_LEN;
        last = sz % AESGROUP_LEN;
        
        //CBC
        aes_set_key(&ctx, key, AESKEY_LEN * 8);
        for (i = 0; i < group; i++) {
                int gi = i * AESGROUP_LEN;
                aes_encrypt(&ctx, &src[gi], &dst[gi]);
        }

        //OFB
        if (last) {
                if (group) {
                        memcpy(tail, &dst[(group - 1) * AESGROUP_LEN], sizeof(tail));
                } else {
                        memcpy(tail, AESIV, sizeof(tail));
                }
                aes_encrypt(&ctx, tail, tail);
                for (i = 0; i < last; i++) {
                        int gi = group * AESGROUP_LEN;
                        dst[gi + i] = src[gi + i]^tail[i];
                }
        }
        return ;
}

static void
aes_decode(uint8_t key[AESKEY_LEN], const uint8_t *src, uint8_t *dst, int sz)
{
        int i;
        int group;
        int last;
        uint8_t tail[AESGROUP_LEN];
        aes_context ctx;

        group = sz / AESGROUP_LEN;
        last = sz % AESGROUP_LEN;
        
        aes_set_key(&ctx, key, AESKEY_LEN * 8);
        if (last) {
                if (group) {
                        int gi = (group - 1) * AESGROUP_LEN;
                        memcpy(tail, &src[gi], sizeof(tail));
                } else {
                        memcpy(tail, AESIV, sizeof(tail));
                }
        }
        //CBC
        for (i = 0; i < group; i++) {
                int gi = i * AESGROUP_LEN;
                aes_decrypt(&ctx, &src[gi], &dst[gi]);
        }
        
        //OFB
        if (last) {
                aes_encrypt(&ctx, tail, tail);
                for (i = 0; i < last; i++) {
                        int gi = group * AESGROUP_LEN;
                        dst[gi + i] = src[gi + i]^tail[i];
                }
        }
        return ;
}

typedef void (* aes_func_t)(
                                uint8_t key[AESKEY_LEN],
                                const uint8_t *src,
                                uint8_t *dst,
                                int sz);

static int
aes_do(lua_State *L, aes_func_t func)
{
        uint8_t key[AESKEY_LEN];
        int data_type;
        size_t key_sz;
        const uint8_t *key_text;

        key_text = (uint8_t *)luaL_checklstring(L, 1, &key_sz);
        if (key_sz > AESKEY_LEN) {
                sha256_context ctx;
                sha256_starts(&ctx);
                sha256_update(&ctx, key_text, key_sz);
                sha256_finish(&ctx, key);
        } else {
                memset(key, 0, sizeof(key));
                memcpy(key, key_text, key_sz);
        }

        data_type = lua_type(L, 2);
        if (data_type == LUA_TSTRING) {
                size_t data_sz;
                const uint8_t *data = (const uint8_t *)luaL_checklstring(L, 2, &data_sz);
                uint8_t *recv = (uint8_t *)lua_newuserdata(L, data_sz);
                func(key, data, recv, data_sz);
                lua_pushlstring(L, (char *)recv, data_sz);
        } else if (data_type == LUA_TUSERDATA) {
                uint8_t *data = (uint8_t *)lua_touserdata(L, 2);
                size_t data_sz = luaL_checkinteger(L, 3);
                func(key, data, data, data_sz);
                lua_pushnil(L);
        } else {
                luaL_error(L, "Invalid content");
        }

        return 1;
}

static int
laesencode(lua_State *L)
{
        return aes_do(L, aes_encode);
}

static int
laesdecode(lua_State *L)
{
        return aes_do(L, aes_decode);
}

int 
luaopen_crypt(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"sha1", lsha1},
                {"randomkey", lrandomkey},
                {"hmac", lhmac_sha1},
                {"aesencode", laesencode},
                {"aesdecode", laesdecode},
                {NULL, NULL},
        };

        luaL_newlib(L, tbl);
        
        return 1;
}
