/*
 * Benchmark: timer subsystem performance
 *
 * Tests the timing wheel, node pool, and flipbuf command pipeline
 * by linking against the real timer.c with minimal stubs.
 *
 * Build:
 *   cd benchmark && make perf_timer
 *
 * Usage:
 *   ./perf_timer [count]
 *   ./perf_timer 100000
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <assert.h>

#include "silly.h"
#include "timer.h"

/*============================================================================
 * Stubs: minimal implementations to satisfy timer.c's external dependencies
 *============================================================================*/

/* mem.c stubs */
void *mem_alloc(size_t sz)
{
	void *p = malloc(sz);
	assert(p);
	return p;
}
void *mem_realloc(void *ptr, size_t sz)
{
	void *p = realloc(ptr, sz);
	assert(p);
	return p;
}
void mem_free(void *ptr) { free(ptr); }

/* log.c stubs */
enum silly_log_level log_get_level(void) { return SILLY_LOG_ERROR; }
void log_write_(enum silly_log_level level, const char *msg, size_t len)
{
	(void)level;
	fwrite(msg, 1, len, stderr);
}
void log_writef_(enum silly_log_level level, const char *fmt, ...)
{
	(void)level;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

/* worker.c stub: timer fires go here; just free the message */
void worker_push(struct silly_message *msg)
{
	if (msg && msg->free)
		msg->free(msg);
}

/*============================================================================
 * Helpers
 *============================================================================*/

static inline uint64_t get_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static inline void sleep_ms(int ms)
{
	struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
	nanosleep(&ts, NULL);
}

struct bench_result {
	const char *name;
	int count;
	double elapsed_ms;
	double ops_per_sec;
};

static void print_result(const struct bench_result *r)
{
	printf("  %-40s  %8d ops  %8.2f ms  %12.0f ops/s\n",
	       r->name, r->count, r->elapsed_ms, r->ops_per_sec);
}

static void fill_result(struct bench_result *r, const char *name,
			int count, uint64_t elapsed_ns)
{
	r->name = name;
	r->count = count;
	r->elapsed_ms = elapsed_ns / 1e6;
	r->ops_per_sec = count / (elapsed_ns / 1e9);
}

/*============================================================================
 * Benchmarks
 *============================================================================*/

/*
 * Bench 1: timer_after throughput (schedule only, no tick)
 *
 * Measures: pool_newnode + flipbuf_write
 * This is what every time.after() call does on the worker thread.
 */
static void bench_schedule(int count, struct bench_result *r)
{
	uint64_t *sessions = malloc(sizeof(uint64_t) * count);

	uint64_t t0 = get_ns();
	for (int i = 0; i < count; i++)
		sessions[i] = timer_after(100000);
	uint64_t t1 = get_ns();

	fill_result(r, "timer_after (schedule)", count, t1 - t0);
	free(sessions);
}

/*
 * Bench 2: timer_cancel throughput
 *
 * Measures: pool_locate + version check + flipbuf_write
 */
static void bench_cancel(int count, struct bench_result *r)
{
	uint64_t *sessions = malloc(sizeof(uint64_t) * count);
	for (int i = 0; i < count; i++)
		sessions[i] = timer_after(100000);
	/* drain the after commands into wheel */
	sleep_ms(TIMER_RESOLUTION + 1);
	timer_update();

	uint64_t t0 = get_ns();
	for (int i = 0; i < count; i++)
		timer_cancel(sessions[i]);
	uint64_t t1 = get_ns();

	fill_result(r, "timer_cancel", count, t1 - t0);
	free(sessions);
}

/*
 * Bench 3: timer_update with pending commands
 *
 * Measures: flipbuf_flip + process_cmd (add_node into timing wheel)
 * Schedule N timers, then one timer_update to process them all.
 */
static void bench_update_add(int count, struct bench_result *r)
{
	uint64_t *sessions = malloc(sizeof(uint64_t) * count);
	for (int i = 0; i < count; i++)
		sessions[i] = timer_after(100000);

	/* ensure enough time passes for timer_update to actually tick */
	sleep_ms(TIMER_RESOLUTION + 1);

	uint64_t t0 = get_ns();
	timer_update();
	uint64_t t1 = get_ns();

	fill_result(r, "timer_update (process adds)", count, t1 - t0);
	free(sessions);
}

/*
 * Bench 4: timer fire throughput
 *
 * Measures: expire_timer + timeout + node_free + pool_freelist
 * Schedule N timers with a short timeout. First update adds them
 * to the wheel. After enough time passes, second update fires them.
 */
static void bench_fire(int count, struct bench_result *r)
{
	/* Use TIMER_RESOLUTION*2 so they don't expire during the first update */
	for (int i = 0; i < count; i++)
		timer_after(TIMER_RESOLUTION * 2);

	/* first tick: process adds into wheel */
	sleep_ms(TIMER_RESOLUTION + 1);
	timer_update();

	/* wait for all timers to expire */
	sleep_ms(TIMER_RESOLUTION * 3);

	/* second tick: fire all expired timers */
	uint64_t t0 = get_ns();
	timer_update();
	uint64_t t1 = get_ns();

	fill_result(r, "timer_update (fire expired)", count, t1 - t0);
}

/*
 * Bench 5: schedule + fire round-trip
 *
 * Measures full lifecycle: after -> add_node -> expire -> free
 * Only times the timer_after + timer_update calls, not sleeps.
 */
static void bench_roundtrip(int count, struct bench_result *r)
{
	uint64_t elapsed = 0;

	uint64_t t0 = get_ns();
	for (int i = 0; i < count; i++)
		timer_after(TIMER_RESOLUTION * 2);
	elapsed += get_ns() - t0;

	sleep_ms(TIMER_RESOLUTION + 1);

	t0 = get_ns();
	timer_update(); /* add to wheel */
	elapsed += get_ns() - t0;

	sleep_ms(TIMER_RESOLUTION * 3);

	t0 = get_ns();
	timer_update(); /* fire */
	elapsed += get_ns() - t0;

	fill_result(r, "roundtrip (after+add+fire+free)", count, elapsed);
}

/*
 * Bench 6: cascade cost
 *
 * Measures the overhead of cascading by running 512 ticks
 * (2 full root rotations) to guarantee multiple cascade events.
 * Reports per-tick cost with N pending higher-level timers.
 */
static void bench_cascade(int count, struct bench_result *r)
{
	uint64_t *sessions = malloc(sizeof(uint64_t) * count);
	int ticks = 512;

	/* Spread timers across level[0..3] with various timeouts */
	for (int i = 0; i < count; i++) {
		int timeout = 3000 + (i % 57000);
		sessions[i] = timer_after(timeout);
	}
	sleep_ms(TIMER_RESOLUTION + 1);
	timer_update(); /* add to wheel */

	/* Sleep enough time for 512 ticks */
	sleep_ms(ticks * TIMER_RESOLUTION + 1);

	uint64_t t0 = get_ns();
	timer_update(); /* processes ~512 ticks, some with cascade */
	uint64_t t1 = get_ns();

	r->name = "cascade (512 ticks, N pending)";
	r->count = ticks;
	r->elapsed_ms = (t1 - t0) / 1e6;
	r->ops_per_sec = ticks / ((t1 - t0) / 1e9);

	free(sessions);
}

/*
 * Bench 7: two-thread contention
 *
 * Simulates the real runtime: worker thread calls timer_after (producer),
 * timer thread calls timer_update (consumer). They contend on flipbuf mutex
 * and pool spinlock.
 */
struct producer_arg {
	int count;
	uint64_t elapsed_ns;
	atomic_int done;
};

static void *producer_thread(void *arg)
{
	struct producer_arg *pa = arg;
	uint64_t t0 = get_ns();
	for (int i = 0; i < pa->count; i++)
		timer_after(100000);
	pa->elapsed_ns = get_ns() - t0;
	atomic_store(&pa->done, 1);
	return NULL;
}

static void bench_contention(int count, struct bench_result *r)
{
	pthread_t tid;
	struct producer_arg pa = {.count = count, .elapsed_ns = 0};
	atomic_init(&pa.done, 0);

	pthread_create(&tid, NULL, producer_thread, &pa);

	/* consumer: keep ticking while producer is running */
	while (!atomic_load(&pa.done)) {
		sleep_ms(TIMER_RESOLUTION + 1);
		timer_update();
	}
	/* drain remaining */
	sleep_ms(TIMER_RESOLUTION + 1);
	timer_update();

	pthread_join(tid, NULL);

	/* report producer-side throughput under contention */
	fill_result(r, "two-thread contention", count, pa.elapsed_ns);
}

/*
 * Bench 8: mixed add/cancel workload
 *
 * Alternates between scheduling and canceling timers,
 * simulating real-world usage patterns.
 * Only times the timer API calls, not the sleeps.
 */
static void bench_mixed(int count, struct bench_result *r)
{
	int batch = 100;
	uint64_t *sessions = malloc(sizeof(uint64_t) * batch);
	int ops = 0;
	uint64_t elapsed = 0;

	while (ops < count) {
		int n = (count - ops < batch) ? count - ops : batch;
		uint64_t t0 = get_ns();
		for (int i = 0; i < n; i++)
			sessions[i] = timer_after(50000);
		elapsed += get_ns() - t0;

		sleep_ms(TIMER_RESOLUTION + 1);

		t0 = get_ns();
		timer_update();
		elapsed += get_ns() - t0;

		t0 = get_ns();
		for (int i = 0; i < n; i++)
			timer_cancel(sessions[i]);
		elapsed += get_ns() - t0;

		sleep_ms(TIMER_RESOLUTION + 1);

		t0 = get_ns();
		timer_update();
		elapsed += get_ns() - t0;

		ops += n;
	}

	fill_result(r, "mixed (batch add+tick+cancel+tick)", count, elapsed);
	free(sessions);
}

/*============================================================================
 * Main
 *============================================================================*/

int main(int argc, char *argv[])
{
	int count = 100000;
	if (argc > 1)
		count = atoi(argv[1]);

	printf("=== Timer Performance Benchmark ===\n");
	printf("Operations: %d, TIMER_RESOLUTION: %d ms\n\n", count,
	       TIMER_RESOLUTION);

	struct bench_result results[8];
	int nr = 0;

	struct {
		const char *label;
		void (*fn)(int, struct bench_result *);
	} benches[] = {
		{"schedule",    bench_schedule},
		{"cancel",      bench_cancel},
		{"update (add)", bench_update_add},
		{"fire",        bench_fire},
		{"roundtrip",   bench_roundtrip},
		{"cascade",     bench_cascade},
		{"contention",  bench_contention},
		{"mixed",       bench_mixed},
	};
	int nbench = sizeof(benches) / sizeof(benches[0]);

	for (int i = 0; i < nbench; i++) {
		printf("Running: %s... ", benches[i].label);
		fflush(stdout);
		timer_init();
		benches[i].fn(count, &results[nr++]);
		timer_stop();
		timer_update();
		timer_exit();
		printf("done\n");
	}

	/* Print results */
	printf("\n%-42s  %8s  %8s  %14s\n",
	       "Benchmark", "Count", "Time", "Throughput");
	printf("----------------------------------------------------------------------"
	       "----------\n");
	for (int i = 0; i < nr; i++)
		print_result(&results[i]);

	return 0;
}
