---@meta silly.errno

-- NOTE: The string values below are illustrative only.
-- Actual runtime values include a numeric suffix like "End of file (10004)",
-- and the numeric code for standard errno (EINTR, EACCES, ...) varies by
-- platform (Linux/macOS/Windows). Do NOT rely on exact string equality with
-- the values declared here; use identity comparison via the errno table
-- (e.g. `err == errno.EOF`) for logic, and treat the string as opaque
-- elsewhere (e.g. logging).

---@enum silly.errno
local M = {
	-- Standard errno
	INTR = "Interrupted system call",
	ACCES = "Permission denied",
	BADF = "Bad file descriptor",
	FAULT = "Bad address",
	INVAL = "Invalid argument",
	MFILE = "Too many open files",
	NFILE = "Too many open files in system",
	NOMEM = "Cannot allocate memory",
	NOBUFS = "No buffer space available",
	NOTSOCK = "Socket operation on non-socket",
	OPNOTSUPP = "Operation not supported",
	AFNOSUPPORT = "Address family not supported by protocol",
	PROTONOSUPPORT = "Protocol not supported",

	ADDRINUSE = "Address already in use",
	ADDRNOTAVAIL = "Cannot assign requested address",
	NETDOWN = "Network is down",
	NETUNREACH = "Network is unreachable",
	NETRESET = "Network dropped connection on reset",
	HOSTUNREACH = "No route to host",
	CONNABORTED = "Software caused connection abort",
	CONNRESET = "Connection reset by peer",
	CONNREFUSED = "Connection refused",
	TIMEDOUT = "Operation timed out",
	ISCONN = "Transport endpoint is already connected",
	NOTCONN = "Transport endpoint is not connected",
	INPROGRESS = "Operation now in progress",
	ALREADY = "Operation already in progress",
	AGAIN = "Resource temporarily unavailable",
	WOULDBLOCK = "Operation would block",
	PIPE = "Broken pipe",
	DESTADDRREQ = "Destination address required",
	MSGSIZE = "Message too long",
	PROTOTYPE = "Protocol wrong type for socket",
	NOPROTOOPT = "Protocol not available",

	-- Custom EX* errors
	RESOLVE = "Address resolution failed",
	NOSOCKET = "No free socket available",
	CLOSING = "Socket is closing",
	CLOSED = "Socket is closed",
	EOF = "End of file",
	TLS = "TLS error",
}
return M
