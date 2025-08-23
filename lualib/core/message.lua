local M = { -- keep sync with silly.h
	SIGNAL = 1,
	STDIN = 2,
	TIMER_EXPIRE = 3,
	SOCKET_LISTEN = 4,
	SOCKET_CONNECT = 5,
	SOCKET_ACCEPT = 6,
	SOCKET_DATA = 7,
	SOCKET_UDP = 8,
	SOCKET_CLOSE = 9,
	HIVE_DONE = 10,
}

return M