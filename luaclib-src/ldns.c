#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <limits.h>
#ifdef __WIN32
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "luastr.h"

// DNS wire format constants
#define DNS_HDR_SIZE     12
#define DNS_RR_FIXED     10   // TYPE(2) + CLASS(2) + TTL(4) + RDLEN(2)
#define DNS_QFIXED       4    // QTYPE(2) + QCLASS(2)

// Header flags
#define DNS_FLAG_QR      0x8000
#define DNS_FLAG_RD      0x0100
#define DNS_FLAG_TC_BIT  9
#define DNS_RCODE_MASK   0x000F

// Name compression
#define DNS_MAX_NAME     256
#define DNS_PTR_DEPTH    128
#define DNS_PTR_MASK     0xC0
#define DNS_PTR_HIGH_MASK 0x3F
#define DNS_MAX_RR       1000  // sanity cap on total resource records

// Record types
#define DNS_TYPE_A       1
#define DNS_TYPE_CNAME   5
#define DNS_TYPE_SOA     6
#define DNS_TYPE_AAAA    28
#define DNS_TYPE_SRV     33
#define DNS_TYPE_OPT     41

// Record data sizes
#define DNS_IPV4_LEN     4
#define DNS_IPV6_LEN     16
#define DNS_SRV_FIXED    6    // priority(2) + weight(2) + port(2)
#define DNS_SOA_FIXED    20   // SERIAL(4)+REFRESH(4)+RETRY(4)+EXPIRE(4)+MINIMUM(4)

// EDNS0
#define DNS_EDNS0_UDP    4096
#define DNS_CLASS_IN     1

// TTL conversion
#define DNS_TTL_TO_MS    1000

static inline uint16_t unpack_u16(const uint8_t *p, size_t pos)
{
	return ((unsigned int)p[pos] << 8) | p[pos + 1];
}

static inline uint32_t unpack_u32(const uint8_t *p, size_t pos)
{
	return ((uint32_t)p[pos] << 24) |
	       ((uint32_t)p[pos + 1] << 16) |
	       ((uint32_t)p[pos + 2] << 8) |
	       (uint32_t)p[pos + 3];
}

static int lresolvconf(lua_State *L)
{
	return silly_push_resolvconf(L);
}

static int lhosts(lua_State *L)
{
	return silly_push_hosts(L);
}

static int ldotcount(lua_State *L)
{
	size_t len;
	const char *name = luaL_checklstring(L, 1, &len);
	int dots = 0;
	for (size_t i = 0; i < len; i++) {
		if (name[i] == '.')
			dots++;
	}
	lua_pushinteger(L, dots);
	return 1;
}

/* Validate a domain name per RFC 1035 §2.3.4.
 * Each label must be 1-63 bytes; total name ≤ 253 bytes.
 * Empty labels (adjacent dots, leading dot) are rejected.
 * A single trailing dot (FQDN) is allowed. */
static int lvalidname(lua_State *L)
{
	size_t len;
	const char *name = luaL_checklstring(L, 1, &len);
	if (len == 0 || len > 253) {
		lua_pushboolean(L, 0);
		return 1;
	}
	size_t label_len = 0;
	for (size_t i = 0; i < len; i++) {
		if (name[i] == '.') {
			if (label_len == 0 || label_len > 63) {
				lua_pushboolean(L, 0);
				return 1;
			}
			label_len = 0;
		} else {
			label_len++;
		}
	}
	// last label: 0 is ok only if trailing dot (FQDN)
	if (label_len > 63) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, 1);
	return 1;
}

// lquestion: build DNS query packet

static inline void q_header(luaL_Buffer *buf, lua_Integer id)
{
	uint8_t hdr[DNS_HDR_SIZE];
	hdr[0] = (id >> 8) & 0xFF;
	hdr[1] = id & 0xFF;
	hdr[2] = (DNS_FLAG_RD >> 8) & 0xFF;
	hdr[3] = DNS_FLAG_RD & 0xFF;
	hdr[4] = 0x00; hdr[5] = 0x01; // QDCOUNT=1
	hdr[6] = 0x00; hdr[7] = 0x00; // ANCOUNT=0
	hdr[8] = 0x00; hdr[9] = 0x00; // NSCOUNT=0
	hdr[10] = 0x00; hdr[11] = 0x01; // ARCOUNT=1 (EDNS0 OPT)
	luaL_addlstring(buf, (const char *)hdr, DNS_HDR_SIZE);
}

static inline void q_name(luaL_Buffer *buf, const struct luastr *name)
{
	const char *p = (const char *)name->str;
	const char *end = p + name->len;
	while (p < end) {
		const char *dot = memchr(p, '.', end - p);
		if (dot == NULL)
			dot = end;
		size_t len = (size_t)(dot - p);
		if (len > 0) { // skip trailing dot (FQDN)
			luaL_addchar(buf, (uint8_t)len);
			luaL_addlstring(buf, p, len);
		}
		p += len + 1;
	}
	luaL_addchar(buf, '\0');
}

static inline void q_type(luaL_Buffer *buf, lua_Integer qtype)
{
	uint8_t qt[DNS_QFIXED];
	qt[0] = (qtype >> 8) & 0xFF;
	qt[1] = qtype & 0xFF;
	qt[2] = (DNS_CLASS_IN >> 8) & 0xFF;
	qt[3] = DNS_CLASS_IN & 0xFF;
	luaL_addlstring(buf, (const char *)qt, DNS_QFIXED);
}

static inline void q_opt(luaL_Buffer *buf)
{
	uint8_t opt[11];
	opt[0] = 0x00;          // root name
	opt[1] = (DNS_TYPE_OPT >> 8) & 0xFF;
	opt[2] = DNS_TYPE_OPT & 0xFF;
	opt[3] = (DNS_EDNS0_UDP >> 8) & 0xFF;
	opt[4] = DNS_EDNS0_UDP & 0xFF;
	opt[5] = 0x00; opt[6] = 0x00; opt[7] = 0x00; opt[8] = 0x00; // TTL=0
	opt[9] = 0x00; opt[10] = 0x00; // RDLEN=0
	luaL_addlstring(buf, (const char *)opt, 11);
}

// c.question(name, qtype, id) -> string
static int lquestion(lua_State *L)
{
	luaL_Buffer buf;
	struct luastr name;
	lua_Integer qtype, id;
	luastr_check(L, 1, &name);
	qtype = luaL_checkinteger(L, 2);
	id = luaL_checkinteger(L, 3);
	luaL_argcheck(L, qtype > 0 && qtype <= 0xFFFF, 2, "invalid qtype");
	luaL_argcheck(L, id >= 0 && id <= 0xFFFF, 3, "invalid id");
	luaL_buffinit(L, &buf);
	q_header(&buf, id);
	q_name(&buf, &name);
	q_type(&buf, qtype);
	q_opt(&buf);
	luaL_pushresult(&buf);
	return 1;
}

// lanswer: parse complete DNS response
struct buf {
	uint8_t *p;
	size_t size;
	size_t offset;
};

struct rr_ctx {
	lua_State *L;              // luaState
	const uint8_t *p;          // start of DNS message
	size_t size;               // size of DNS message
	const char *qname;         // question name for SOA-negative mapping
	size_t qnamelen;           // length of qname
	int rtype;                 // current RR TYPE
	size_t rdlen;              // current RDATA length
	size_t rdpos;              // RDATA start offset
	lua_Integer ttl;           // current RR TTL (raw wire seconds)
	char rname[DNS_MAX_NAME];  // current RR owner name
	size_t namelen;            // length of rname
};

/* Read a DNS name from msg at position pos (0-based).
 * Handles compression pointers. Writes dot-separated lowercase name to out.
 * Returns new position after the name field, or 0 on error. */
static size_t read_name(const struct buf *in, struct buf *out)
{
	const uint8_t *p = (const uint8_t *)in->p;
	size_t size = in->size;
	size_t pos = in->offset;
	int depth = 0;
	size_t saved_pos = 0;
	int done = 0;
	while (depth++ < DNS_PTR_DEPTH && pos < size) {
		uint32_t c = p[pos++];
		if (c == 0) {
			done = 1;
			break;
		} else if ((c & DNS_PTR_MASK) == DNS_PTR_MASK) {
			size_t off;
			if (pos >= size)
				return 0;
			off = ((c & DNS_PTR_HIGH_MASK) << 8) | p[pos];
			if (off >= pos - 1)
				return 0;
			if (!saved_pos)
				saved_pos = pos + 1;
			pos = off;
		} else {
			// c is label length (RFC 1035: max 63)
			if (c > 63) // guard malformed label length
				return 0;
			if (pos + c > size || out->offset + c + 1 >= out->size)
				return 0;
			for (size_t i = 0; i < c; i++) {
				out->p[out->offset++] = tolower((uint8_t)p[pos + i]);
			}
			out->p[out->offset++] = '.';
			pos += c;
		}
	}
	if (!done)
		return 0;
	if (saved_pos == 0)
		saved_pos = pos;
	if (out->offset > 0)
		out->offset--;
	out->p[out->offset] = '\0'; // trim trailing dot from the assembled name
	return saved_pos;
}

/* Begin a new record: push table and set name(1), rtype(2), ttl_ms(3).
 * Caller should then push rdata and store it at index 4, or leave it unset
 * for SOA-negative mapping records. */
static inline void rr_begin(struct rr_ctx *ctx)
{
	lua_createtable(ctx->L, 4, 0);
	lua_pushlstring(ctx->L, ctx->rname, ctx->namelen);
	lua_rawseti(ctx->L, -2, 1);
	lua_pushinteger(ctx->L, ctx->rtype);
	lua_rawseti(ctx->L, -2, 2);
	lua_pushinteger(ctx->L, ctx->ttl * DNS_TTL_TO_MS);
	lua_rawseti(ctx->L, -2, 3);
}

/* Parse RR header: read owner name, TYPE, CLASS, TTL, RDLEN.
 * Populates ctx->rname/namelen, rtype, ttl, rdlen, rdpos.
 * Returns 0 on success, -1 on error. */
static int parse_rr_begin(struct rr_ctx *ctx, size_t pos)
{
	const uint8_t *msg = ctx->p;
	struct buf in = {
		.p = (uint8_t *)msg,
		.size = ctx->size,
		.offset = pos,
	};
	struct buf rrname = {
		.p = (uint8_t *)ctx->rname,
		.size = sizeof(ctx->rname),
		.offset = 0,
	};
	size_t next = read_name(&in, &rrname);
	if (next == 0 || (next + DNS_RR_FIXED > ctx->size))
		return -1;
	ctx->namelen = rrname.offset;
	// RR fixed header at next: TYPE(0..1), CLASS(2..3), TTL(4..7), RDLEN(8..9).
	ctx->rtype = unpack_u16(msg, next);
	// CLASS is currently ignored: unpack_u16(msg, next + 2).
	ctx->ttl = unpack_u32(msg, next + 4);
	ctx->rdlen = unpack_u16(msg, next + 8);
	next += DNS_RR_FIXED;
	if (next + ctx->rdlen > ctx->size)
		return -1;
	ctx->rdpos = next;
	return 0;
}

static inline int parse_rr_a(struct rr_ctx *ctx)
{
	if (ctx->rdlen < DNS_IPV4_LEN)
		return -1;
	const uint8_t *rdata = ctx->p + ctx->rdpos;
	char ipbuf[INET_ADDRSTRLEN];
	inet_ntop(AF_INET, rdata, ipbuf, sizeof(ipbuf));
	lua_pushstring(ctx->L, ipbuf);
	return 0;
}

static inline int parse_rr_aaaa(struct rr_ctx *ctx)
{
	if (ctx->rdlen < DNS_IPV6_LEN)
		return -1;
	const uint8_t *rdata = ctx->p + ctx->rdpos;
	char ipbuf[INET6_ADDRSTRLEN];
	inet_ntop(AF_INET6, rdata, ipbuf, sizeof(ipbuf));
	lua_pushstring(ctx->L, ipbuf);
	return 0;
}

static inline int parse_rr_cname(struct rr_ctx *ctx)
{
	char cnamebuf[DNS_MAX_NAME];
	struct buf in = {
		.p = (uint8_t *)ctx->p,
		.size = ctx->size,
		.offset = ctx->rdpos,
	};
	struct buf cname = {
		.p = (uint8_t *)cnamebuf,
		.size = sizeof(cnamebuf),
		.offset = 0,
	};
	if (read_name(&in, &cname) == 0)
		return -1;
	lua_pushlstring(ctx->L, cnamebuf, cname.offset);
	return 0;
}

static inline int parse_rr_srv(struct rr_ctx *ctx)
{
	if (ctx->rdlen < DNS_SRV_FIXED)
		return -1;
	lua_State *L = ctx->L;
	size_t pos = ctx->rdpos;
	int priority = unpack_u16(ctx->p, pos);
	int weight = unpack_u16(ctx->p, pos + 2);
	int port = unpack_u16(ctx->p, pos + 4);
	char targetbuf[DNS_MAX_NAME];
	struct buf in = {
		.p = (uint8_t *)ctx->p,
		.size = ctx->size,
		.offset = ctx->rdpos + DNS_SRV_FIXED,
	};
	struct buf target = {
		.p = (uint8_t *)targetbuf,
		.size = sizeof(targetbuf),
		.offset = 0,
	};
	if (read_name(&in, &target) == 0)
		return -1;
	lua_createtable(L, 0, 4);
	lua_pushinteger(L, priority);
	lua_setfield(L, -2, "priority");
	lua_pushinteger(L, weight);
	lua_setfield(L, -2, "weight");
	lua_pushinteger(L, port);
	lua_setfield(L, -2, "port");
	lua_pushlstring(L, targetbuf, target.offset);
	lua_setfield(L, -2, "target");
	return 0;
}

static inline int parse_rr_soa(struct rr_ctx *ctx)
{
	size_t newpos, min_off;
	lua_Integer minimum;
	// SOA RDATA: MNAME + RNAME + 5*uint32
	char skipbuf[DNS_MAX_NAME];
	struct buf in = {
		.p = (uint8_t *)ctx->p,
		.size = ctx->size,
		.offset = ctx->rdpos,
	};
	struct buf skip = {
		.p = (uint8_t *)skipbuf,
		.size = sizeof(skipbuf),
		.offset = 0,
	};
	newpos = read_name(&in, &skip); // MNAME
	if (newpos == 0)
		return -1;
	skip.offset = 0;
	in.offset = newpos;
	newpos = read_name(&in, &skip); // RNAME
	if (newpos == 0)
		return -1;
	if (newpos + DNS_SOA_FIXED > ctx->size)
		return -1;
	// MINIMUM is the last uint32 in the 5-field block
	min_off = newpos + DNS_SOA_FIXED - 4;
	minimum = unpack_u32(ctx->p, min_off);
	if (ctx->ttl > minimum)
		ctx->ttl = minimum;
	return 0;
}

static int push_rr(struct rr_ctx *ctx)
{
	int ret;
	rr_begin(ctx);
	switch (ctx->rtype) {
	case DNS_TYPE_A:
		ret = parse_rr_a(ctx);
		break;
	case DNS_TYPE_AAAA:
		ret = parse_rr_aaaa(ctx);
		break;
	case DNS_TYPE_CNAME:
		ret = parse_rr_cname(ctx);
		break;
	case DNS_TYPE_SRV:
		ret = parse_rr_srv(ctx);
		break;
	default:
		// OPT(41) and unsupported types are skipped here.
		ret = -1;
		break;
	}
	if (ret >= 0) {
		lua_rawseti(ctx->L, -2, 4);
	} else {
		lua_pop(ctx->L, 1); // pop unfinished rr table
	}
	return ret;
}

/* Parse up to count RRs from msgb->offset and return a Lua array table.
 * Includes answer/authority/additional sections in wire order.
 * SOA records are interpreted as negative caching TTL and mapped to qtype. */
static int push_rrs(lua_State *L, struct buf *msgb,
	int count, struct buf *qname, int qtype)
{
	int tbl, n = 0;
	struct rr_ctx ctx = {
		.L = L,
		.p = msgb->p,
		.size = msgb->size,
		.qname = (const char *)qname->p,
		.qnamelen = qname->offset,
	};
	size_t offset = msgb->offset;
	lua_createtable(L, count, 0);
	tbl = lua_gettop(L);
	for (int i = 0; i < count; i++) {
		int ret;
		if (parse_rr_begin(&ctx, offset) < 0)
			break;
		offset = ctx.rdpos + ctx.rdlen;
		if (ctx.rtype == DNS_TYPE_SOA) {
			ret = parse_rr_soa(&ctx);
			if (ret >= 0) {
				ctx.rtype = qtype;
				ctx.namelen = ctx.qnamelen;
				memcpy(ctx.rname, ctx.qname, ctx.qnamelen + 1);
				rr_begin(&ctx);
			}
		} else {
			ret = push_rr(&ctx);
		}
		if (ret >= 0) {
			lua_rawseti(L, tbl, ++n);
		}
	}
	return n;
}

/* c.answer(msg) -> id, name, qtype, tc, records
 * Parse a complete DNS response: header, question section, and resource records.
 * tc is true when the response is truncated (TC bit set).
 * records is always a table (possibly empty); caller uses #records > 0.
 * Returns nil (single) if msg is not a valid DNS response. */
static int lanswer(lua_State *L)
{
	int top;
	struct luastr msgl;
	struct buf msgb, qname;
	uint32_t id, flags, qtype;
	char qnamebuf[DNS_MAX_NAME];  // question name
	luastr_check(L, 1, &msgl);
	top = lua_gettop(L);
	// Need at least DNS_HDR_SIZE bytes for header
	if (msgl.len < DNS_HDR_SIZE) {
		lua_pushnil(L);
		return 1;
	}
	msgb.p = (uint8_t *)msgl.str;
	msgb.size = msgl.len;
	msgb.offset = 0;
	// Parse header
	flags = unpack_u16(msgb.p, 2);
	// Must be a response (QR=1)
	if (!(flags & DNS_FLAG_QR)) {
		lua_pushnil(L);
		return 1;
	}
	id = unpack_u16(msgb.p, 0);
	int tc = (flags >> DNS_FLAG_TC_BIT) & 1;
	int rcode = flags & DNS_RCODE_MASK;
	int qdcount = unpack_u16(msgb.p, 4);
	int ancount = unpack_u16(msgb.p, 6);
	int nscount = unpack_u16(msgb.p, 8);
	int arcount = unpack_u16(msgb.p, 10);
	// Parse question section: only support single-question responses
	if (qdcount != 1) {
		lua_pushnil(L);
		return 1;
	}
	msgb.offset = DNS_HDR_SIZE;
	qname.p = (uint8_t *)qnamebuf;
	qname.size = sizeof(qnamebuf);
	qname.offset = 0;
	size_t newpos = read_name(&msgb, &qname);
	if (newpos == 0) {
		lua_pushnil(L);
		return 1;
	}
	msgb.offset = newpos;
	if ((size_t)msgb.offset + DNS_QFIXED > msgb.size) {
		lua_pushnil(L);
		return 1;
	}
	qtype = unpack_u16(msgb.p, msgb.offset);
	msgb.offset += DNS_QFIXED; // skip QTYPE(2) + QCLASS(2)
	// Push fixed return values: id, name, qtype, tc
	lua_pushinteger(L, id);
	lua_pushlstring(L, (const char *)qname.p, qname.offset);
	lua_pushinteger(L, qtype);
	lua_pushboolean(L, tc);
	if (tc) {
		return 4;
	}
	// Parse resource records (authority section has SOA for negative)
	int total_rr = (rcode != 0 ? 0 : ancount) + nscount + arcount;
	if (total_rr > DNS_MAX_RR) {
		lua_settop(L, top);
		lua_pushnil(L);
		return 1;
	}
	push_rrs(L, &msgb, total_rr, &qname, (int)qtype);
	return 5;
}

SILLY_MOD_API int
luaopen_silly_net_dns_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"resolvconf", lresolvconf},
		{"hosts",      lhosts     },
		{"dotcount",   ldotcount  },
		{"validname",  lvalidname },
		{"question",   lquestion  },
		{"answer",     lanswer    },
		{NULL,         NULL       },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
