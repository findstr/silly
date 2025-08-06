#include "silly.h"
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <liburing.h>
#include <unistd.h>
#include <sys/eventfd.h>
#include <poll.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/stat.h>

#include "silly_log.h"
#include "silly_malloc.h"
#include "silly_conf.h"
#include "socket.h"

#include "event.h"

#define URING_SQ_ENTRIES 512
#define URING_CQ_ENTRIES 8192

#define URING_RECV_BUF_SIZE 1024
#define URING_RECV_BUF_NUM (8192*2)

#define RECV_BUF_GROUP_ID 0

#define OP_EVENT	(1)
#define OP_ACCEPT	(2)
#define OP_CONNECT	(3)
#define OP_SEND		(4)
#define OP_RECV		(5)
#define OP_CANCEL	(6)

#define FOFF(s) ((s)->sid & (MAX_SOCKET_COUNT - 1))

struct ctx {
	uint8_t op;
	struct ctx *next;
	struct socket *s;
	union sockaddr_full addr;
};

struct ctx_chunk {
	struct ctx_chunk *next;
	struct ctx buf[URING_SQ_ENTRIES];
};

struct event {
	struct io_uring ring;
	int xeventcap;
	int xi;
	struct xevent *xeventbuf;
	int eventfd;
	void *recv_bp;                      // recv buffer pool
	struct io_uring_buf_ring *recv_br;  // recv buffer ring
	struct ctx_chunk *ctx_chunk;
	struct ctx *ctx_free;
	int pending;
};

static struct io_uring_sqe *get_sqe(struct event *ev)
{
	struct io_uring_sqe *sqe;
	struct io_uring *ring = &ev->ring;
	for (;;) {
		sqe = io_uring_get_sqe(ring);
		if (sqe)
			break;
		io_uring_submit(ring);
		sqe = io_uring_get_sqe(ring);
		if (sqe)
			break;
		usleep(1);
	}
	return sqe;
}

static struct ctx *get_ctx(struct event *ev)
{
	struct ctx *ctx;
	struct ctx_chunk *chunk;
	if (ev->ctx_free == NULL) {
		chunk = silly_malloc(sizeof(struct ctx_chunk));
		chunk->next = ev->ctx_chunk;
		ev->ctx_chunk = chunk;
		for (size_t i = 0; i < ARRAY_SIZE(chunk->buf); i++) {
			ctx = &chunk->buf[i];
			ctx->next = ev->ctx_free;
			ev->ctx_free = ctx;
		}
	}
	ctx = ev->ctx_free;
	ev->ctx_free = ctx->next;
	ctx->next = NULL;
	return ctx;
}

static void free_ctx(struct event *ev, struct ctx *ctx)
{
	ctx->next = ev->ctx_free;
	ev->ctx_free = ctx;
}

static void cancel_req(struct event *ev, struct socket *s)
{
	struct io_uring_sqe *sqe = get_sqe(ev);
	struct ctx *ctx = get_ctx(ev);
	ctx->op = OP_CANCEL;
	ctx->s = s;
	io_uring_sqe_set_data(sqe, ctx);
	io_uring_prep_cancel_fd(sqe, s->fd, 0);
}

static void accept_multishot_req(struct event *ev, struct socket *s)
{
	struct io_uring_sqe *sqe = get_sqe(ev);
	struct ctx *ctx = get_ctx(ev);
	ctx->op = OP_ACCEPT;
	ctx->s = s;
	io_uring_sqe_set_data(sqe, ctx);
	io_uring_prep_multishot_accept(sqe, s->fd, NULL, NULL, 0);
}

static void recv_multishot_req(struct event *ev, struct socket *s)
{
	struct io_uring_sqe *sqe = get_sqe(ev);
	struct ctx *ctx = get_ctx(ev);
	ctx->op = OP_RECV;
	ctx->s = s;
	io_uring_sqe_set_data(sqe, ctx);
	io_uring_prep_recv_multishot(sqe, FOFF(s), NULL, 0, 0);
	sqe->flags |= IOSQE_BUFFER_SELECT | IOSQE_FIXED_FILE;
	sqe->buf_group = RECV_BUF_GROUP_ID;
}

static void connect_req(struct event *ev, struct socket *s, const struct sockaddr *addr, socklen_t addrlen)
{
	struct io_uring_sqe *sqe = get_sqe(ev);
	struct ctx *ctx = get_ctx(ev);
	ctx->op = OP_CONNECT;
	ctx->s = s;
	io_uring_sqe_set_data(sqe, ctx);
	io_uring_prep_connect(sqe, s->fd, addr, addrlen);
}

static int init_recv_buffer_ring(struct event *ev)
{
	size_t pool_size;
	size_t ring_size;
	void *buf_pool;
	struct io_uring_buf_ring *buf_ring;

	pool_size = URING_RECV_BUF_SIZE * URING_RECV_BUF_NUM;
	buf_pool = silly_malloc(pool_size);
	if (buf_pool == NULL) {
		return -1;
	}
	memset(buf_pool, 0, pool_size);
	ring_size = sizeof(struct io_uring_buf_ring) + URING_RECV_BUF_NUM * sizeof(struct io_uring_buf);
	if (posix_memalign((void **)&buf_ring, 4096, ring_size) != 0) {
		silly_free(buf_pool);
		return -1;
	}
	io_uring_buf_ring_init(buf_ring);
	struct io_uring_buf_reg reg = {
		.ring_addr = (uint64_t)buf_ring,
		.ring_entries = URING_RECV_BUF_NUM,
		.bgid = RECV_BUF_GROUP_ID,
		.resv = {0, 0, 0}
	};
	int ret = io_uring_register_buf_ring(&ev->ring, &reg, 0);
	if (ret < 0) {
		silly_free(buf_ring);
		silly_free(buf_pool);
		return -1;
	}
	for (int i = 0; i < URING_RECV_BUF_NUM; i++) {
		void *buf = (void *)((uintptr_t)buf_pool + i * URING_RECV_BUF_SIZE);
		io_uring_buf_ring_add(buf_ring, buf, URING_RECV_BUF_SIZE, i,
			io_uring_buf_ring_mask(URING_RECV_BUF_NUM), i);
	}
	io_uring_buf_ring_advance(buf_ring, URING_RECV_BUF_NUM);
	ev->recv_bp = buf_pool;
	ev->recv_br = buf_ring;
	return 0;
}

static void recycle_recv_buffer(struct event *ev, int bid)
{
	assert(bid >= 0 && bid < URING_RECV_BUF_NUM);
	void *buf = (void *)((uintptr_t)ev->recv_bp + bid * URING_RECV_BUF_SIZE);
	io_uring_buf_ring_add(ev->recv_br, buf, URING_RECV_BUF_SIZE, bid,
		io_uring_buf_ring_mask(URING_RECV_BUF_NUM), 0);
	io_uring_buf_ring_advance(ev->recv_br, 1);
}


struct event *event_new(int nr)
{
	int ret;
	struct io_uring_params params;
	struct event *ev = silly_malloc(sizeof(struct event));
	if (!ev) {
		return NULL;
	}
	memset(ev, 0, sizeof(*ev));

	memset(&params, 0, sizeof(params));
	params.flags |= IORING_SETUP_SINGLE_ISSUER;
	params.flags |= IORING_SETUP_CLAMP;
	params.flags |= IORING_SETUP_CQSIZE;
	params.cq_entries = URING_CQ_ENTRIES;
	params.flags |= IORING_SETUP_DEFER_TASKRUN;
	params.flags |= IORING_SETUP_COOP_TASKRUN;
	params.flags |= IORING_SETUP_TASKRUN_FLAG;

	ret = io_uring_queue_init_params(URING_SQ_ENTRIES, &ev->ring, &params);
	if (ret < 0) {
		silly_log_error("[uring] queue init fail:%d\n", ret);
		errno = -ret;
		goto fail;
	}
	if (!(ev->ring.features & IORING_FEAT_NODROP)) {
		silly_log_error("[uring] queue not support nodrop\n");
		errno = -EINVAL;
		goto fail;
	}
	ret = io_uring_register_files_sparse(&ev->ring, MAX_SOCKET_COUNT);
	if (ret < 0) {
		silly_log_error("[uring] register files fail:%d\n", ret);
		errno = -ret;
		goto fail;
	}
	ret = init_recv_buffer_ring(ev);
	if (ret < 0) {
		silly_log_error("[uring] init recv buffer fail:%d\n", ret);
		goto fail;
	}
	ev->eventfd = eventfd(0, EFD_CLOEXEC);
	if (ev->eventfd < 0) {
		silly_log_error("[uring] eventfd init fail:%d\n", errno);
		goto fail;
	}
	// Initialize xevent buffer
	ev->xeventcap = nr;
	ev->xeventbuf = silly_malloc(sizeof(struct xevent) * nr);
	if (!ev->xeventbuf) {
		silly_log_error("[uring] init xevent buffer fail\n");
		goto fail;
	}
	ev->xi = 0;
	ev->ctx_chunk = NULL;
	ev->ctx_free = NULL;

	struct io_uring_sqe *sqe = get_sqe(ev);
	struct ctx *ctx = get_ctx(ev);
	ctx->op = OP_EVENT;
	io_uring_sqe_set_data(sqe, ctx);
	io_uring_prep_poll_add(sqe, ev->eventfd, POLLIN);
	io_uring_submit(&ev->ring);
	return ev;
fail:
	event_free(ev);
	return NULL;
}

void event_free(struct event *ev)
{
	if (!ev)
		return;
	if (ev->recv_bp) {
		silly_free(ev->recv_bp);
	}
	if (ev->recv_br) {
		io_uring_unregister_buf_ring(&ev->ring, RECV_BUF_GROUP_ID);
		free(ev->recv_br);
	}
	if (ev->eventfd >= 0) {
		close(ev->eventfd);
	}
	if (ev->xeventbuf) {
		silly_free(ev->xeventbuf);
	}
	for (struct ctx_chunk *chunk = ev->ctx_chunk; chunk != NULL; ) {
		struct ctx_chunk *next = chunk->next;
		silly_free(chunk);
		chunk = next;
	}
	silly_free(ev);
	io_uring_unregister_files(&ev->ring);
	io_uring_queue_exit(&ev->ring);
}

void event_wait(struct event *ev)
{
	io_uring_submit_and_wait(&ev->ring, 1);
}

void event_wakeup(struct event *ev)
{
	int ret;
	eventfd_t value = 1;
	for (;;) {
		ret = eventfd_write(ev->eventfd, value);
		if (ret == 0)
			return;
	}
}

int event_nudge(struct event *ev)
{
	eventfd_t value;
	while (eventfd_read(ev->eventfd, &value) < 0) {}
	assert(value > 0);
	return value;
}

int event_accept(struct event *ev, struct socket *s)
{
	accept_multishot_req(ev, s);
	return 0;
}

int event_add(struct event *ev, struct socket *s)
{
	io_uring_register_files_update(&ev->ring, FOFF(s), &s->fd, 1);
	recv_multishot_req(ev, s);
	set_reading(s);
	return 0;
}

int event_close(struct event *ev, struct socket *s)
{
	int ret;
	int fd = -1;
	assert(s->fd >= 0);
	assert(!is_reading(s));
	assert(!is_writing(s));
	ret = io_uring_register_files_update(&ev->ring, FOFF(s), &fd, 1);
	if (ret < 0) {
		silly_log_error("[uring] register files update fail:%d\n", ret);
		return -1;
	}
	return 0;
}

void event_read_enable(struct event *ev, struct socket *s, int enable)
{
	//TODO:
}

void event_connect(struct event *ev, struct socket *s, union sockaddr_full *addr)
{
	set_connecting(s);
	connect_req(ev, s, (struct sockaddr *)addr, sizeof(*addr));
}

void event_tcpsend(struct event *ev, struct socket *s, uint8_t *data, size_t sz, void (*finalizer)(void *))
{
	struct ctx *ctx;
	struct io_uring_sqe *sqe;
	struct mvec *mvec;
	iomsg_append(&s->sendmsg, data, sz, finalizer);
	if (is_writing(s)) {
		return;
	}
	set_writing(s);
	iomsg_flip(&s->sendmsg);
	mvec = &s->sendmsg.vecs[s->sendmsg.sending];
	s->sendmsg.hdr.msg_iov = mvec->iov;
	s->sendmsg.hdr.msg_iovlen = mvec->len;
	sqe = get_sqe(ev);
	ctx = get_ctx(ev);
	ctx->op = OP_SEND;
	ctx->s = s;
	io_uring_sqe_set_data(sqe, ctx);
	io_uring_sqe_set_flags(sqe, IOSQE_FIXED_FILE);
	io_uring_prep_sendmsg(sqe, FOFF(s), &s->sendmsg.hdr, MSG_WAITALL | MSG_NOSIGNAL);
}

void event_udpsend(struct event *ev, struct socket *s, uint8_t *data,
	size_t size, void (*finalizer)(void *), const union sockaddr_full *addr)
{
	//TODO:
}

static struct xevent *push_xevent(struct event *ev, int op, struct socket *s)
{
	struct xevent *xe;
	if (ev->xi >= ev->xeventcap) {
		ev->xeventcap *= 2;
		ev->xeventbuf = silly_realloc(ev->xeventbuf, sizeof(struct xevent) * ev->xeventcap);
	}
	xe = &ev->xeventbuf[ev->xi++];
	xe->op = op;
	xe->s = s;
	return xe;
}

static void handle_accept(struct event *ev, struct ctx *ctx, struct io_uring_cqe *cqe)
{
	struct xevent *xe;
	socklen_t len;
	if (cqe->res < 0) {
		silly_log_error("[uring] accept failed: %d", -cqe->res);
		return;
	}
	xe = push_xevent(ev, XEVENT_ACCEPT, ctx->s);
	xe->fd = cqe->res;
	len = sizeof(xe->addr);
	getpeername(xe->fd, (struct sockaddr*)&xe->addr, &len);
	if (!(cqe->flags & IORING_CQE_F_MORE)) {
		if (!is_close_local(ctx->s)) {
			accept_multishot_req(ev, ctx->s);
			struct io_uring_sqe *sqe = get_sqe(ev);
			io_uring_sqe_set_data(sqe, ctx);
			io_uring_prep_multishot_accept(sqe, ctx->s->fd, NULL, NULL, 0);
		} else {
			free_ctx(ev, ctx);
		}
	}
}

static void handle_connect(struct event *ev, struct ctx *ctx, struct io_uring_cqe *cqe)
{
	assert(is_connecting(ctx->s));
	struct xevent *xe = push_xevent(ev, XEVENT_CONNECT, ctx->s);
	xe->err = cqe->res;
	if (cqe->res >= 0) {
		clear_connecting(ctx->s);
		free_ctx(ev, ctx);
		recv_multishot_req(ev, ctx->s);
	}
}

static void handle_send(struct event *ev, struct ctx *ctx, struct io_uring_cqe *cqe)
{
	assert(is_writing(ctx->s));
	if (cqe->res < 0) {
		silly_log_error("[uring] send failed: %d\n", -cqe->res);
		set_close_remote(ctx->s);
		clear_writing(ctx->s);
		wlist_free(ctx->s);
		iomsg_free(&ctx->s->sendmsg);
		if (is_reading(ctx->s)) {
			cancel_req(ev, ctx->s);
		} else {
			struct xevent *xe = push_xevent(ev, XEVENT_CLOSE, ctx->s);
			xe->err = -cqe->res;
		}
		free_ctx(ev, ctx);
		return;
	}
	struct socket *s = ctx->s;
	struct mvec *mvec = &s->sendmsg.vecs[s->sendmsg.sending];
	int bytes = cqe->res;
	ssize_t offset = mvec->offset;
	assert(ctx->s->sendmsg.hdr.msg_iov == &mvec->iov[mvec->curiov]);
	for (; mvec->curiov < mvec->len; mvec->curiov++) {
		int i = mvec->curiov;
		struct iovec *iov = &mvec->iov[i];
		ssize_t left = iov->iov_len - offset;
		ssize_t once = bytes < left ? bytes : left;
		assert(iov->iov_len > offset);
		iov->iov_len -= once;
		bytes -= once;
		if (iov->iov_len == 0) {
			mvec->finv[i](iov->iov_base - offset);
			offset = 0;
		} else {
			assert(bytes == 0);
			offset += once;
			iov->iov_base += once;
			break;
		}
	}
	mvec->offset = (int)offset;
	if (mvec->curiov >= mvec->len) { // all data sent
		iomsg_flip(&s->sendmsg);
	}
	mvec = &s->sendmsg.vecs[s->sendmsg.sending];
	if (mvec->curiov < mvec->len) { // has padding data
		struct io_uring_sqe *sqe = get_sqe(ev);
		io_uring_sqe_set_data(sqe, ctx);
		io_uring_sqe_set_flags(sqe, IOSQE_FIXED_FILE);
		s->sendmsg.hdr.msg_iov = &mvec->iov[mvec->curiov];
		s->sendmsg.hdr.msg_iovlen = mvec->len - mvec->curiov;
		if (s->sendmsg.hdr.msg_iovlen >= IOV_MAX) {
			s->sendmsg.hdr.msg_iovlen = IOV_MAX;
		}
		io_uring_prep_sendmsg(sqe, FOFF(s), &s->sendmsg.hdr, MSG_WAITALL | MSG_NOSIGNAL);
	} else {
		clear_writing(s);
	}
}

static void handle_recv(struct event *ev, struct ctx *ctx, struct io_uring_cqe *cqe)
{
	struct xevent *xe;
	if (cqe->res <= 0) {
		if (cqe->res != 0 && cqe->res != -ECANCELED) {
			silly_log_error("[uring] recv buffer not selected :%d\n", -cqe->res);
		}
		if (cqe->res == -ENOBUFS) {
			struct io_uring_sqe *sqe = get_sqe(ev);
			io_uring_sqe_set_data(sqe, ctx);
			io_uring_prep_recv_multishot(sqe, ctx->s->fd, NULL, 0, 0);
			sqe->flags |= IOSQE_BUFFER_SELECT;
			sqe->buf_group = RECV_BUF_GROUP_ID;
			return ;
		}
		if (is_writing(ctx->s)) {
			return;
		}
		xe = push_xevent(ev, XEVENT_CLOSE, ctx->s);
		xe->err = -cqe->res;
		free_ctx(ev, ctx);
		return;
	}
	if (cqe->flags & IORING_CQE_F_BUFFER) {
		assert(cqe->res > 0);
		unsigned int bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
		const void *buf = (void *)((uintptr_t)ev->recv_bp + bid * URING_RECV_BUF_SIZE);
		xe = push_xevent(ev, XEVENT_READ, ctx->s);
		xe->buf = silly_malloc(cqe->res);
		xe->len = cqe->res;
		memcpy(xe->buf, buf, cqe->res);
		recycle_recv_buffer(ev, bid);
	}
	if (!(cqe->flags & IORING_CQE_F_MORE) && !is_close_any(ctx->s)) {
		struct io_uring_sqe *sqe = get_sqe(ev);
		io_uring_sqe_set_data(sqe, ctx);
		io_uring_prep_recv_multishot(sqe, ctx->s->fd, NULL, 0, 0);
		sqe->flags |= IOSQE_BUFFER_SELECT;
		sqe->buf_group = RECV_BUF_GROUP_ID;
	}
}

struct xevent *event_process(struct event *ev, int *n)
{
	unsigned head;
	unsigned count = 0;
	struct ctx *ctx;
	struct io_uring_sqe *sqe;
	struct io_uring_cqe *cqe;
	ev->xi = 0;
	if (ev->ring.sq.kflags && (*ev->ring.sq.kflags & IORING_SQ_CQ_OVERFLOW)) {
		silly_log_error("[uring] SQ reports CQ overflow flag\n");
	}
	io_uring_for_each_cqe(&ev->ring, head, cqe) {
		count++;
		ctx = io_uring_cqe_get_data(cqe);
		switch (ctx->op) {
		case OP_EVENT:
			sqe = get_sqe(ev);
			io_uring_prep_poll_add(sqe, ev->eventfd, POLLIN);
			io_uring_sqe_set_data(sqe, ctx);
			break;
		case OP_CANCEL:
			free_ctx(ev, ctx);
			break;
		case OP_ACCEPT:
			handle_accept(ev, ctx, cqe);
			break;
		case OP_CONNECT:
			handle_connect(ev, ctx, cqe);
			break;
		case OP_SEND:
			handle_send(ev, ctx, cqe);
			break;
		case OP_RECV:
			handle_recv(ev, ctx, cqe);
			break;
		default:
			silly_log_error("[uring] unhandled op:%d", ctx->op);
			free_ctx(ev, ctx);
			assert(!"unknow op");
			break;
		}
	}
	io_uring_cq_advance(&ev->ring, count);
	*n = ev->xi;
	return ev->xeventbuf;
}
