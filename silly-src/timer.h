/**
=========================================================================
 Author: findstr
 Email: findstr@sina.com
 File Name: /home/findstr/code/silly/server-src/timer.h
 Description: (C)  2015-07  findstr
   
 Edit History: 
   2015-07-05    File created.
=========================================================================
**/
#ifndef _TIMER_H
#define _TIMER_H

int timer_init();
void timer_exit();

int timer_add(int time, void (*cb)(void *ud), void *ud);

int timer_dispatch();


#endif


