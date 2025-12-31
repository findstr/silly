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

#include "engine.h"

struct {
	volatile int running;
	int exitstatus;
	int workerstatus; /* 0:sleep 1:running */
	const struct boot_args *conf;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	pthread_t sockettid;
	pthread_t timertid;
} R;

static void *thread_timer(void *arg)
{
	(void)arg;
	log_info("[timer] start\n");
	for (;;) {
		struct timespec req;
		int sleep = timer_update();
		if (sleep < 0)
			break;
		req.tv_sec = sleep / 1000;
		req.tv_nsec = (sleep % 1000) * 1000000;
		nanosleep(&req, NULL);
		if (R.workerstatus == 0)
			pthread_cond_signal(&R.cond);
	}
	log_info("[timer] stop\n");
	return NULL;
}

static void *thread_socket(void *arg)
{
	(void)arg;
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
	while (R.running) {
		//allow spurious wakeup, it's harmless
		R.workerstatus = 0;
		if (worker_backlog() == 0) //double check
			pthread_cond_wait(&R.cond, &R.mutex);
		R.workerstatus = 1;
		worker_dispatch();
		log_flush();
	}
	log_info("[worker] stop\n");
	pthread_mutex_unlock(&R.mutex);
	return NULL;
}

static void thread_monitor()
{
	struct timespec req;
	req.tv_sec = MONITOR_MSG_SLOW_TIME / 1000;
	req.tv_nsec = (MONITOR_MSG_SLOW_TIME % 1000) * 1000000;
	log_info("[monitor] start\n");
	for (;;) {
		if (R.running == 0)
			break;
		nanosleep(&req, NULL);
		monitor_check();
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

int engine_run(const struct boot_args *config)
{
	int err;
	R.running = 1;
	R.conf = config;
	R.exitstatus = 0;
	pthread_t workertid;
	pthread_mutex_init(&R.mutex, NULL);
	pthread_cond_init(&R.cond, NULL);
	sig_init();
	err = socket_init();
	if (unlikely(err < 0)) {
		log_error("%s socket init fail:%d\n", config->selfname, err);
		return -err;
	}
	worker_init();
	monitor_init();
	srand(time(NULL));
	log_info("%s %s is running ...\n", config->selfname, SILLY_RELEASE);
	log_info("cpu affinity setting, timer:%d, socket:%d, worker:%d\n",
		 config->timeraffinity, config->socketaffinity,
		 config->workeraffinity);
	thread_create(&R.sockettid, thread_socket, NULL, config->socketaffinity);
	thread_create(&R.timertid, thread_timer, NULL, config->timeraffinity);
	thread_create(&workertid, thread_worker, (void *)config,
		      config->workeraffinity);
	thread_monitor();
	pthread_join(workertid, NULL);
	log_flush();
	pthread_mutex_destroy(&R.mutex);
	pthread_cond_destroy(&R.cond);
	worker_exit();
	socket_exit();
	log_info("%s has already exit...\n", config->selfname);
	return R.exitstatus;
}

void engine_shutdown(int status)
{
	R.running = 0;
	R.exitstatus = status;
	timer_stop();
	socket_stop();
	pthread_join(R.timertid, NULL);
	pthread_join(R.sockettid, NULL);
}
