#if defined(__WIN32)

#include <stdio.h>
#include <string.h>
#include <ws2tcpip.h> /* socklen_t, et al (MSVC20xx) */
#include <windows.h>
#include <io.h>
#include <afunix.h>

#include "silly_log.h"
#include "net.h"
#include "pipe.h"

int pipe_read(SOCKET sock, void *buf, size_t len)
{
	size_t readn = 0;
	while (readn < len) {
		int n = recv(sock, (char *)buf + readn, len - readn, 0);
		if (n < 0) {
			if (WSAGetLastError() == WSAEINTR)
				continue;
			return -1;
		}
		if (n == 0)
			return -1;
		readn += n;
	}
	return (int)readn;
}

int pipe_write(SOCKET sock, void *buf, size_t len)
{
	size_t writen = 0;
	while (writen < len) {
		int n = send(sock, (char *)buf + writen, len - writen, 0);
		if (n < 0) {
			if (WSAGetLastError() == WSAEINTR)
				continue;
			return -1;
		}
		if (n == 0)
			return -1;
		writen += n;
	}
	return (int)writen;
}

int pipe(fd_t socks[2])
{
	union {
		struct sockaddr_un unaddr;
		struct sockaddr_in inaddr;
		struct sockaddr addr;
	} a;
	SOCKET listener;
	int e, ii;
	int domain = AF_UNIX;
	int make_overlapped = 0;
	socklen_t addrlen = sizeof(a.unaddr);
	DWORD flags = (make_overlapped ? WSA_FLAG_OVERLAPPED : 0);
	int reuse = 1;

	if (socks == 0) {
		WSASetLastError(WSAEINVAL);
		return SOCKET_ERROR;
	}
	socks[0] = socks[1] = -1;

	for (ii = 0; ii < 2; ii++) {
		listener = socket(domain, SOCK_STREAM,
				  domain == AF_INET ? IPPROTO_TCP : 0);
		if (listener == INVALID_SOCKET)
			goto fallback;

		memset(&a, 0, sizeof(a));
		if (domain == AF_UNIX) {
			/* XX: Abstract sockets (filesystem-independent) don't work, contrary to
             * the claims of the aforementioned blog post:
             * https://github.com/microsoft/WSL/issues/4240#issuecomment-549663217
             *
             * So we must use a named path, and that comes with all the attendant
             * problems of permissions and collisions. Trying various temporary
             * directories and putting high-res time and PID in the filename, that
             * seems like a less-bad option.
             */
			LARGE_INTEGER ticks;
			DWORD n = 0;
			int bind_try = 0;

			for (;;) {
				switch (bind_try++) {
				case 0:
					/* "The returned string ends with a backslash" */
					n = GetTempPath(UNIX_PATH_MAX,
							a.unaddr.sun_path);
					break;
				case 1:
					/* Heckuva job with API consistency, Microsoft!
                     * unless the Windows directory is the root directory."
                     */
					n = GetWindowsDirectory(
						a.unaddr.sun_path,
						UNIX_PATH_MAX);
					n += snprintf(a.unaddr.sun_path + n,
						      UNIX_PATH_MAX - n,
						      "\\Temp\\");
					break;
				case 2:
					n = snprintf(a.unaddr.sun_path,
						     UNIX_PATH_MAX,
						     "C:\\Temp\\");
					break;
				case 3:
					n = 0; /* Current directory */
					break;
				case 4:
					goto fallback;
				}

				/* GetTempFileName could be used here.
                 * (https://docs.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettempfilenamea)
                 * However it only adds 16 bits of time-based random bits,
                 * fails if there isn't room for a 14-character filename, and
                 * seems to offers no other apparent advantages. So we will
                 * use high-res timer ticks and PID for filename.
                 */
				QueryPerformanceCounter(&ticks);
				snprintf(a.unaddr.sun_path + n,
					 UNIX_PATH_MAX - n, "%lld_%lu",
					 ticks.QuadPart, GetCurrentProcessId());
				a.unaddr.sun_family = AF_UNIX;

				if (bind(listener, &a.addr, addrlen) !=
				    SOCKET_ERROR)
					break;
			}
		} else {
			a.inaddr.sin_family = AF_INET;
			a.inaddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
			a.inaddr.sin_port = 0;

			if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR,
				       (char *)&reuse,
				       (socklen_t)sizeof(reuse)) == -1)
				goto fallback;
			;

			if (bind(listener, &a.addr, addrlen) == SOCKET_ERROR)
				goto fallback;

			memset(&a, 0, sizeof(a));
			if (getsockname(listener, &a.addr, &addrlen) ==
			    SOCKET_ERROR)
				goto fallback;

			// win32 getsockname may only set the port number, p=0.0005.
			// ( https://docs.microsoft.com/windows/win32/api/winsock/nf-winsock-getsockname ):
			a.inaddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
			a.inaddr.sin_family = AF_INET;
		}

		if (listen(listener, 1) == SOCKET_ERROR)
			goto fallback;

		socks[0] = WSASocket(domain, SOCK_STREAM, 0, NULL, 0, flags);
		if ((SOCKET)socks[0] == INVALID_SOCKET)
			goto fallback;
		if (connect(socks[0], &a.addr, addrlen) == SOCKET_ERROR)
			goto fallback;

		socks[1] = accept(listener, NULL, NULL);
		if ((SOCKET)socks[1] == INVALID_SOCKET)
			goto fallback;

		closesocket(listener);
		return 0;

fallback:
		/* AF_UNIX/SOCK_STREAM became available in Windows 10:
         * https://devblogs.microsoft.com/commandline/af_unix-comes-to-windows
         *
         * We need to fallback to AF_INET on earlier versions of Windows,
         * or if setting up AF_UNIX socket fails in any other way.
         */
		domain = AF_INET;
		addrlen = sizeof(a.inaddr);

		e = WSAGetLastError();
		closesocket(listener);
		closesocket(socks[0]);
		closesocket(socks[1]);
		WSASetLastError(e);
	}

	socks[0] = socks[1] = -1;
	return SOCKET_ERROR;
}

#endif