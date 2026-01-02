/*
 * Benchmark: spinlock vs pthread_mutex performance comparison
 *
 * Tests different lock implementations under the same workload pattern
 * as silly's message queue (MPSC: multiple producers, single consumer).
 *
 * Build:
 *   gcc -O2 -Wall -pthread -o perf_lock perf_lock.c
 *
 * Usage:
 *   ./perf_lock [threads] [operations_per_thread]
 *   ./perf_lock 4 1000000
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#if defined(__x86_64__)
#include <immintrin.h>
#define cpu_pause() _mm_pause()
#elif defined(__aarch64__)
#define cpu_pause() __asm__ __volatile__("yield" ::: "memory")
#else
#define cpu_pause() ((void)0)
#endif

/*============================================================================
 * Lock implementations
 *============================================================================*/

/* 1. Custom atomic spinlock (no pthread) */
typedef atomic_int atomic_spinlock_t;

static inline void atomic_spinlock_init(atomic_spinlock_t *lock)
{
	atomic_init(lock, 0);
}

static inline void atomic_spinlock_lock(atomic_spinlock_t *lock)
{
	for (;;) {
		if (!atomic_exchange_explicit(lock, 1, memory_order_acquire))
			return;
		while (atomic_load_explicit(lock, memory_order_relaxed))
			cpu_pause();
	}
}

static inline void atomic_spinlock_unlock(atomic_spinlock_t *lock)
{
	atomic_store_explicit(lock, 0, memory_order_release);
}

/* 2. pthread_spinlock_t wrapper */
typedef pthread_spinlock_t pthread_spin_t;

static inline void pthread_spin_wrapper_init(pthread_spin_t *lock)
{
	pthread_spin_init(lock, PTHREAD_PROCESS_PRIVATE);
}

static inline void pthread_spin_wrapper_lock(pthread_spin_t *lock)
{
	pthread_spin_lock(lock);
}

static inline void pthread_spin_wrapper_unlock(pthread_spin_t *lock)
{
	pthread_spin_unlock(lock);
}

/* 3. pthread_mutex (default) */
typedef pthread_mutex_t mutex_default_t;

static inline void mutex_default_init(mutex_default_t *lock)
{
	pthread_mutex_init(lock, NULL);
}

static inline void mutex_default_lock(mutex_default_t *lock)
{
	pthread_mutex_lock(lock);
}

static inline void mutex_default_unlock(mutex_default_t *lock)
{
	pthread_mutex_unlock(lock);
}

/* 4. pthread_mutex (adaptive) */
typedef pthread_mutex_t mutex_adaptive_t;

static inline void mutex_adaptive_init(mutex_adaptive_t *lock)
{
	pthread_mutexattr_t attr;
	pthread_mutexattr_init(&attr);
	pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ADAPTIVE_NP);
	pthread_mutex_init(lock, &attr);
	pthread_mutexattr_destroy(&attr);
}

static inline void mutex_adaptive_lock(mutex_adaptive_t *lock)
{
	pthread_mutex_lock(lock);
}

static inline void mutex_adaptive_unlock(mutex_adaptive_t *lock)
{
	pthread_mutex_unlock(lock);
}

/*============================================================================
 * Test infrastructure
 *============================================================================*/

#define CACHE_LINE_SIZE 64

struct node {
	struct node *next;
	uint64_t value;
};

/* Simulates queue.c structure */
struct test_queue {
	union {
		struct {
			struct node *head;
			struct node **tail;
			size_t size;
		};
		char pad1[CACHE_LINE_SIZE];
	};
	union {
		atomic_spinlock_t atomic_lock;
		pthread_spin_t pthread_spin;
		mutex_default_t mutex_default;
		mutex_adaptive_t mutex_adaptive;
		char pad2[CACHE_LINE_SIZE];
	};
};

struct thread_arg {
	int id;
	int ops;
	struct test_queue *queue;
	void (*lock_fn)(void *);
	void (*unlock_fn)(void *);
	uint64_t latency_sum;
	uint64_t latency_max;
};

static atomic_int ready_count;
static atomic_int start_flag;

static inline uint64_t get_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

/* Producer thread: simulates queue_push */
static void *producer_thread(void *arg)
{
	struct thread_arg *ta = arg;
	struct test_queue *q = ta->queue;
	uint64_t lat_sum = 0, lat_max = 0;

	/* Signal ready and wait for start */
	atomic_fetch_add(&ready_count, 1);
	while (!atomic_load(&start_flag))
		cpu_pause();

	for (int i = 0; i < ta->ops; i++) {
		struct node *n = malloc(sizeof(*n));
		n->value = (uint64_t)ta->id << 32 | i;
		n->next = NULL;

		uint64_t t0 = get_ns();

		/* Critical section: same as queue_push */
		ta->lock_fn(&q->atomic_lock);
		*q->tail = n;
		q->tail = &n->next;
		q->size++;
		ta->unlock_fn(&q->atomic_lock);

		uint64_t lat = get_ns() - t0;
		lat_sum += lat;
		if (lat > lat_max)
			lat_max = lat;
	}

	ta->latency_sum = lat_sum;
	ta->latency_max = lat_max;
	return NULL;
}

/* Consumer thread: simulates queue_pop */
static void *consumer_thread(void *arg)
{
	struct thread_arg *ta = arg;
	struct test_queue *q = ta->queue;
	int total_ops = ta->ops;
	int consumed = 0;

	/* Signal ready and wait for start */
	atomic_fetch_add(&ready_count, 1);
	while (!atomic_load(&start_flag))
		cpu_pause();

	while (consumed < total_ops) {
		ta->lock_fn(&q->atomic_lock);
		if (q->head == NULL) {
			ta->unlock_fn(&q->atomic_lock);
			cpu_pause();
			continue;
		}
		struct node *batch = q->head;
		q->head = NULL;
		q->tail = &q->head;
		q->size = 0;
		ta->unlock_fn(&q->atomic_lock);

		/* Process batch outside lock */
		while (batch) {
			struct node *next = batch->next;
			free(batch);
			batch = next;
			consumed++;
		}
	}
	return NULL;
}

/*============================================================================
 * Benchmark runner
 *============================================================================*/

struct benchmark_result {
	const char *name;
	double throughput;    /* ops/sec */
	double avg_latency;   /* ns */
	double max_latency;   /* ns */
};

static void run_benchmark(const char *name,
			  void (*init_fn)(void *),
			  void (*lock_fn)(void *),
			  void (*unlock_fn)(void *),
			  int num_producers,
			  int ops_per_producer,
			  struct benchmark_result *result)
{
	struct test_queue queue;
	pthread_t *producers;
	pthread_t consumer;
	struct thread_arg *producer_args;
	struct thread_arg consumer_arg;
	int total_ops = num_producers * ops_per_producer;

	/* Initialize queue */
	queue.head = NULL;
	queue.tail = &queue.head;
	queue.size = 0;
	init_fn(&queue.atomic_lock);

	/* Allocate thread resources */
	producers = malloc(sizeof(pthread_t) * num_producers);
	producer_args = malloc(sizeof(struct thread_arg) * num_producers);

	atomic_store(&ready_count, 0);
	atomic_store(&start_flag, 0);

	/* Setup consumer */
	consumer_arg.id = -1;
	consumer_arg.ops = total_ops;
	consumer_arg.queue = &queue;
	consumer_arg.lock_fn = lock_fn;
	consumer_arg.unlock_fn = unlock_fn;

	/* Create threads */
	pthread_create(&consumer, NULL, consumer_thread, &consumer_arg);

	for (int i = 0; i < num_producers; i++) {
		producer_args[i].id = i;
		producer_args[i].ops = ops_per_producer;
		producer_args[i].queue = &queue;
		producer_args[i].lock_fn = lock_fn;
		producer_args[i].unlock_fn = unlock_fn;
		pthread_create(&producers[i], NULL, producer_thread,
			       &producer_args[i]);
	}

	/* Wait for all threads ready */
	while (atomic_load(&ready_count) < num_producers + 1)
		usleep(100);

	/* Start benchmark */
	uint64_t t_start = get_ns();
	atomic_store(&start_flag, 1);

	/* Wait for completion */
	for (int i = 0; i < num_producers; i++) {
		pthread_join(producers[i], NULL);
	}
	pthread_join(consumer, NULL);

	uint64_t t_end = get_ns();
	double elapsed_sec = (t_end - t_start) / 1e9;

	/* Calculate results */
	uint64_t total_lat_sum = 0;
	uint64_t max_lat = 0;
	for (int i = 0; i < num_producers; i++) {
		total_lat_sum += producer_args[i].latency_sum;
		if (producer_args[i].latency_max > max_lat)
			max_lat = producer_args[i].latency_max;
	}

	result->name = name;
	result->throughput = total_ops / elapsed_sec;
	result->avg_latency = (double)total_lat_sum / total_ops;
	result->max_latency = (double)max_lat;

	free(producers);
	free(producer_args);
}

/*============================================================================
 * Main
 *============================================================================*/

int main(int argc, char *argv[])
{
	int num_threads = 4;
	int ops_per_thread = 1000000;

	if (argc > 1)
		num_threads = atoi(argv[1]);
	if (argc > 2)
		ops_per_thread = atoi(argv[2]);

	printf("=== Lock Performance Benchmark ===\n");
	printf("Producers: %d, Operations/producer: %d, Total: %d\n\n",
	       num_threads, ops_per_thread, num_threads * ops_per_thread);

	struct benchmark_result results[4];

	printf("Running: atomic_spinlock... ");
	fflush(stdout);
	run_benchmark("atomic_spinlock",
		      (void (*)(void *))atomic_spinlock_init,
		      (void (*)(void *))atomic_spinlock_lock,
		      (void (*)(void *))atomic_spinlock_unlock,
		      num_threads, ops_per_thread, &results[0]);
	printf("done\n");

	printf("Running: pthread_spinlock... ");
	fflush(stdout);
	run_benchmark("pthread_spinlock",
		      (void (*)(void *))pthread_spin_wrapper_init,
		      (void (*)(void *))pthread_spin_wrapper_lock,
		      (void (*)(void *))pthread_spin_wrapper_unlock,
		      num_threads, ops_per_thread, &results[1]);
	printf("done\n");

	printf("Running: mutex_default... ");
	fflush(stdout);
	run_benchmark("mutex_default",
		      (void (*)(void *))mutex_default_init,
		      (void (*)(void *))mutex_default_lock,
		      (void (*)(void *))mutex_default_unlock,
		      num_threads, ops_per_thread, &results[2]);
	printf("done\n");

	printf("Running: mutex_adaptive... ");
	fflush(stdout);
	run_benchmark("mutex_adaptive",
		      (void (*)(void *))mutex_adaptive_init,
		      (void (*)(void *))mutex_adaptive_lock,
		      (void (*)(void *))mutex_adaptive_unlock,
		      num_threads, ops_per_thread, &results[3]);
	printf("done\n");

	/* Print results */
	printf("\n");
	printf("%-20s %15s %15s %15s\n",
	       "Lock Type", "Throughput", "Avg Latency", "Max Latency");
	printf("%-20s %15s %15s %15s\n",
	       "", "(Mops/s)", "(ns)", "(ns)");
	printf("--------------------------------------------------------------------\n");

	for (int i = 0; i < 4; i++) {
		printf("%-20s %15.2f %15.1f %15.0f\n",
		       results[i].name,
		       results[i].throughput / 1e6,
		       results[i].avg_latency,
		       results[i].max_latency);
	}

	/* Comparison */
	printf("\n");
	printf("Relative to atomic_spinlock:\n");
	for (int i = 1; i < 4; i++) {
		double ratio = results[i].throughput / results[0].throughput;
		printf("  %-18s: %.1f%% throughput\n",
		       results[i].name, ratio * 100);
	}

	return 0;
}
