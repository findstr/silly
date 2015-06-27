/**
=========================================================================
 Author: findstr
 Email: findstr@sina.com
 File Name: sock.h
 Description: (C)  2014-12  findstr
   
 Edit History: 
   2014-12-30    File created.
=========================================================================
**/
#ifndef _SOCK_H
#define _SOCK_H

#define max(a, b)       ((a) > (b) ? (a) : (b))

int socket_write(int s, char *buff, int len);
int socket_read(int s, char *buff, int len);
int socket_read_line(int s, char *buff, int len);

#endif
