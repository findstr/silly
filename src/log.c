#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/time.h>
#include <stdatomic.h>

#include "silly.h"
#include "compiler.h"
#include "platform.h"
#include "mem.h"
#include "timer.h"
#include "trace.h"
#include "log.h"

static int is_daemon = 0;
static enum silly_log_level log_level = SILLY_LOG_INFO;

#define BUILD_SEC (1)
#define BUILD_TRACE (2)
#define BUILD_NONE (3)

struct log_buf {
	char *buf;
	size_t size;
	atomic_uint_least32_t read_pos;
	atomic_uint_least32_t write_pos;
	pthread_mutex_t lock;
};

static struct log_buf *LB;

/* ---- head formatting (per-thread, lock-free) ---- */
static THREAD_LOCAL struct {
	char buf[64];
	char *sstr;
	char *tstr;
	char *term;
	time_t sec;
	time_t msec;
	silly_traceid_t traceid;
	int head_len;
} head_cache = {
	"", NULL, NULL, NULL, 0, 0, 0, 0,
};

#define HEAD_LEN(h) ((size_t)((h).term + 2 - (h).buf))

static char level_names[] = {
	'D',
	'I',
	'W',
	'E',
};

static char hex[] = {
	'0', '1', '2', '3', '4', '5', '6', '7',
	'8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
};


static inline void fmttime()
{
	int n;
	char *end;
	struct tm tm;
	uint64_t now = timer_now();
	time_t sec = now / 1000;
	silly_traceid_t traceid = trace_current();
	int build_step;
	if (head_cache.sstr == NULL) {
		build_step = BUILD_SEC;
		head_cache.sstr = head_cache.buf;
	} else if (sec != head_cache.sec) {
		build_step = BUILD_SEC;
		head_cache.sec = sec;
	} else if (traceid != head_cache.traceid) {
		build_step = BUILD_TRACE;
		head_cache.traceid = traceid;
	} else {
		build_step = BUILD_NONE;
	}
	switch (build_step) {
	case BUILD_SEC:
		end = &head_cache.buf[sizeof(head_cache.buf)];
		localtime_r(&sec, &tm);
		n = strftime(head_cache.sstr, end - head_cache.sstr,
			     "%Y-%m-%d %H:%M:%S ", &tm);
		head_cache.tstr = head_cache.sstr + n;
		//fallthrough
	case BUILD_TRACE:
		for (n = 15; n >= 0; n--) {
			head_cache.tstr[n] = hex[traceid & 0xf];
			traceid >>= 4;
		}
		head_cache.tstr[16] = ' ';
		head_cache.term = head_cache.tstr + 17;
		break;
	}
	return;
}

/* ---- ring buffer write ---- */

static inline size_t ring_used(void)
{
	size_t w = atomic_load_explicit(&LB->write_pos, memory_order_relaxed);
	size_t r = atomic_load_explicit(&LB->read_pos, memory_order_relaxed);
	if (w >= r)
		return w - r;
	return LB->size - r + w;
}

static inline size_t ring_available(void)
{
	return LB->size - ring_used() - 1;
}

static size_t block_write(int fd, const char *buf, size_t len)
{
	size_t total = 0;
	while (len > 0) {
		ssize_t n = write(fd, buf, len);
		if (n > 0) {
			buf += n;
			len -= n;
			total += n;
		} else if (n == 0) {
			/* write returned 0, shouldn't happen but avoid infinite loop */
			break;
		} else if (errno == EINTR) {
			/* interrupted, retry */
			continue;
		} else {
			/* real error: write errno to stderr */
			fprintf(stderr, "[log] write error:%d\n", errno);
			break;
		}
	}
	return total;
}

static size_t block_writev(int fd, const char *buf1, size_t len1,
			   const char *buf2, size_t len2)
{
	struct iovec iov[2];
	size_t total = len1 + len2;
	size_t written = 0;
	iov[0].iov_base = (void *)buf1;
	iov[0].iov_len  = len1;
	iov[1].iov_base = (void *)buf2;
	iov[1].iov_len  = len2;
	while (written < total) {
		ssize_t n = writev(fd, iov, 2);
		if (n > 0) {
			written += n;
			size_t consume = min((size_t)n, iov[0].iov_len);
			iov[0].iov_base = (char *)iov[0].iov_base + consume;
			iov[0].iov_len -= consume;
			n -= consume;
			if (n > 0) {
				iov[1].iov_base = (char *)iov[1].iov_base + n;
				iov[1].iov_len -= n;
			}
		} else if (n == 0) {
			/* write returned 0, shouldn't happen but avoid infinite loop */
			break;
		} else if (errno == EINTR) {
			/* interrupted, retry */
			continue;
		} else {
			/* real error: write errno to stderr */
			fprintf(stderr, "[log] writev error:%d\n", errno);
			break;
		}
	}
	return written;
}

static void ring_flush(void)
{
	size_t start = atomic_load_explicit(&LB->read_pos, memory_order_relaxed);
	size_t end = atomic_load_explicit(&LB->write_pos, memory_order_relaxed);
	size_t n;
	if (start == end)
		return;
	fflush(stdout);
	if (end > start) {
		/* Simple case: data is contiguous */
		n = block_write(STDOUT_FILENO, LB->buf + start, end - start);
		atomic_store_explicit(&LB->read_pos, start + n,
				      memory_order_relaxed);
	} else {
		/* Wrapped case: write both segments atomically */
		n = block_writev(STDOUT_FILENO,
			LB->buf + start, LB->size - start,
			LB->buf, end);
		atomic_store_explicit(&LB->read_pos,
				      (start + n) % LB->size,
				      memory_order_relaxed);
	}
}

/* Copy data into ring buffer, handling wrap-around */
static inline void ring_copy(size_t pos, const char *src, size_t n)
{
	size_t tail = LB->size - pos;
	if (n <= tail) {
		memcpy(LB->buf + pos, src, n);
	} else {
		memcpy(LB->buf + pos, src, tail);
		memcpy(LB->buf, src + tail, n - tail);
	}
}

/* Write head + body to ring buffer (called with lock held) */
static size_t ring_write(const char *data, size_t len)
{
	size_t head_len = HEAD_LEN(head_cache);
	size_t total = len + head_len;
	if (ring_used() > 0 && ring_available() < total) {
		ring_flush();
		if (ring_used() > 0) // Still data left but no space, means fd error
			return 0;
	}
	if (ring_used() == 0 && total >= LB->size) {
		/* If buffer is empty but log is too large, write directly */
		size_t n = block_writev(STDOUT_FILENO,
			head_cache.buf, head_len, data, len);
		if (n == 0)
			return 0;
		return total;
	}
	size_t wpos = atomic_load_explicit(&LB->write_pos, memory_order_relaxed);
	ring_copy(wpos, head_cache.buf, head_len);
	ring_copy((wpos + head_len) % LB->size, data, len);
	atomic_store_explicit(&LB->write_pos, (wpos + total) % LB->size,
			      memory_order_relaxed);
	return total;
}

/* Format log head (thread-local, lock-free) */
static void build_head(enum silly_log_level level)
{
	fmttime();
	head_cache.term[0] = level_names[level];
	head_cache.term[1] = ' ';
}

/* Write head (from head_cache) + body in one lock acquisition */
void log_write_(enum silly_log_level level, const char *body, size_t body_len)
{
	build_head(level);
	pthread_mutex_lock(&LB->lock);
	if (unlikely(ring_write(body, body_len) == 0)) {
		size_t head_len = HEAD_LEN(head_cache);
		fwrite(head_cache.buf, 1, head_len, stderr);
		fwrite(body, 1, body_len, stderr);
	}
	pthread_mutex_unlock(&LB->lock);
}

void log_writef_(enum silly_log_level level, const char *fmt, ...)
{
	int n;
	char tmp[1024];
	char *buf = tmp;
	va_list ap;
	va_start(ap, fmt);
	n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
	va_end(ap);
	if (unlikely(n < 0)) {
		fprintf(stderr, "[log] log_writef_ error: vsnprintf failed\n");
		return;
	}
	if (unlikely((size_t)n >= sizeof(tmp))) {
		size_t need = (size_t)n + 1;
		buf = (char *)mem_alloc(need);
		va_start(ap, fmt);
		n = vsnprintf(buf, need, fmt, ap);
		va_end(ap);
	}
	log_write_(level, buf, n);
	if (unlikely(buf != tmp))
		mem_free(buf);
}

/* ---- public API ---- */

void log_open_file(const char *path)
{
	int fd;
	if (!is_daemon)
		return;
	fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 00666);
	if (fd >= 0) {
		dup2(fd, STDOUT_FILENO);
		close(fd);
	}
}

/*
 * Best-effort flush for crash / abnormal exit scenarios.
 *
 * This function is called from a signal handler (SIGSEGV/SIGABRT) or during
 * atexit() processing (which may be triggered concurrently by exit(-1)).
 * In these scenarios, worker threads might still be active or the process
 * may have crashed while holding the lock.
 *
 * Therefore, we are in a logically unsafe state. We deliberately skip
 * the mutex to avoid deadlock hazards. By making read_pos and write_pos
 * atomic, we ensure memory-safe concurrent access without C-level data
 * race UB. We use memory_order_relaxed instead of acquire/release semantics
 * because normal thread synchronization is handled by the mutex. During a
 * crash, enforcing memory barriers to prevent CPU reordering is unnecessary
 * overhead for the hot path; we accept that we may read logically
 * inconsistent positions mid-write (yielding garbled output), but recovering
 * *some* log data is the priority here. writev() is used as it is
 * async-signal-safe.
 */
static void eh_clean(void)
{
	if (LB == NULL)
		return;
	ring_flush();
}

void log_init(const struct boot_args *config)
{
	LB = (struct log_buf *)mem_alloc(sizeof(*LB));
	LB->buf = (char *)mem_alloc(LOG_BUF_SIZE);
	LB->size = LOG_BUF_SIZE;
	atomic_init(&LB->read_pos, 0);
	atomic_init(&LB->write_pos, 0);
	is_daemon = config->daemon;
	pthread_mutex_init(&LB->lock, NULL);
	log_open_file(config->logpath);
	set_eh(eh_clean);
	atexit(eh_clean);
}

void log_set_level(enum silly_log_level level)
{
	if (level >= ARRAY_SIZE(level_names)) {
		fprintf(stderr, "Invalid log level: %d\n", level);
		return;
	}
	log_level = level;
}

enum silly_log_level log_get_level()
{
	return log_level;
}

void log_flush()
{
	pthread_mutex_lock(&LB->lock);
	ring_flush();
	pthread_mutex_unlock(&LB->lock);
}

void log_exit()
{
	log_flush();
	mem_free(LB->buf);
	pthread_mutex_destroy(&LB->lock);
	mem_free(LB);
	LB = NULL;
}
