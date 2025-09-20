#include "silly_conf.h"
#include <unistd.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include "silly.h"
#include "compiler.h"
#include "trace.h"
#include "log.h"
#include "mem.h"
#include "timer.h"
#include "socket.h"
#include "worker.h"
#include "monitor.h"
#include "sig.h"

#include "run.h"

struct {
	volatile int running;
	int exitstatus;
	int workerstatus; /* 0:sleep 1:running -1:dead */
	const struct boot_args *conf;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
} R;

static void *thread_timer(void *arg)
{
	(void)arg;
	struct timespec req;
	req.tv_sec = TIMER_ACCURACY / 1000;
	req.tv_nsec = (TIMER_ACCURACY % 1000) * 1000000;
	trace_set(TRACE_TIMER_ID);
	log_info("[timer] start\n");
	for (;;) {
		timer_update();
		if (R.workerstatus == -1)
			break;
		nanosleep(&req, NULL);
		if (R.workerstatus == 0)
			pthread_cond_signal(&R.cond);
	}
	log_info("[timer] stop\n");
	socket_terminate();
	return NULL;
}

static void *thread_socket(void *arg)
{
	(void)arg;
	trace_set(TRACE_SOCKET_ID);
	log_info("[socket] start\n");
	for (;;) {
		int err = socket_poll();
		if (err < 0)
			break;
		if (R.workerstatus == 0)
			pthread_cond_signal(&R.cond);
	}
	log_info("[socket] stop\n");
	return NULL;
}

static void *thread_worker(void *arg)
{
	const struct boot_args *c;
	c = (struct boot_args *)arg;
	log_info("[worker] start\n");
	worker_start(c);
	pthread_mutex_lock(&R.mutex);
	trace_set(TRACE_WORKER_ID);
	while (R.running) {
		worker_dispatch();
		//allow spurious wakeup, it's harmless
		R.workerstatus = 0;
		if (worker_msg_size() == 0) //double check
			pthread_cond_wait(&R.cond, &R.mutex);
		R.workerstatus = 1;
		log_flush();
	}
	log_info("[worker] stop\n");
	pthread_mutex_unlock(&R.mutex);
	R.workerstatus = -1;
	return NULL;
}

static void monitor_check()
{
	struct timespec req;
	req.tv_sec = MONITOR_MSG_SLOW_TIME / 1000;
	req.tv_nsec = (MONITOR_MSG_SLOW_TIME % 1000) * 1000000;
	trace_set(TRACE_MONITOR_ID);
	log_info("[monitor] start\n");
	for (;;) {
		if (R.workerstatus == -1)
			break;
		nanosleep(&req, NULL);
		silly_monitor_check();
	}
	log_info("[monitor] stop\n");
	return;
}

static void thread_create(pthread_t *tid, void *(*start)(void *), void *arg,
			  int cpuid)
{
	int err;
	err = pthread_create(tid, NULL, start, arg);
	if (unlikely(err < 0)) {
		log_error("thread create fail:%d\n", err);
		exit(-1);
	}
#ifdef USE_CPU_AFFINITY
	if (cpuid < 0)
		return;
	cpu_set_t cpuset;
	CPU_ZERO(&cpuset);
	CPU_SET(cpuid, &cpuset);
	pthread_setaffinity_np(*tid, sizeof(cpuset), &cpuset);
#else
	(void)cpuid;
#endif
	return;
}

int silly_run(const struct boot_args *config)
{
	int i;
	int err;
	pthread_t pid[3];
	R.running = 1;
	R.conf = config;
	R.exitstatus = 0;
	pthread_mutex_init(&R.mutex, NULL);
	pthread_cond_init(&R.cond, NULL);
	sig_init();
	err = socket_init();
	if (unlikely(err < 0)) {
		log_error("%s socket init fail:%d\n", config->selfname, err);
		return -err;
	}
	worker_init();
	silly_monitor_init();
	srand(time(NULL));
	log_info("%s %s is running ...\n", config->selfname, SILLY_RELEASE);
	log_info("cpu affinity setting, timer:%d, socket:%d, worker:%d\n",
		 config->timeraffinity, config->socketaffinity,
		 config->workeraffinity);
	thread_create(&pid[0], thread_socket, NULL, config->socketaffinity);
	thread_create(&pid[1], thread_timer, NULL, config->timeraffinity);
	thread_create(&pid[2], thread_worker, (void *)config,
		      config->workeraffinity);
	monitor_check();
	for (i = 0; i < 3; i++)
		pthread_join(pid[i], NULL);
	log_flush();
	pthread_mutex_destroy(&R.mutex);
	pthread_cond_destroy(&R.cond);
	worker_exit();
	socket_exit();
	log_info("%s has already exit...\n", config->selfname);
	return R.exitstatus;
}

void silly_shutdown(int status)
{
	R.running = 0;
	R.exitstatus = status;
}
