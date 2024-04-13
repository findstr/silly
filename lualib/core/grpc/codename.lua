local code = require "core.grpc.code"
--[gRPC documentation]: https:--github.com/grpc/grpc/blob/master/doc/statuscodes.md
local M = {
	OK = code.OK,
	CANCELLED = code.Canceled,
	UNKNOWN = code.Unknown,
	INVALID_ARGUMENT = code.InvalidArgument,
	DEADLINE_EXCEEDED = code.DeadlineExceeded,
	NOT_FOUND = code.NotFound,
	ALREADY_EXISTS = code.AlreadyExists,
	PERMISSION_DENIED = code.PermissionDenied,
	RESOURCE_EXHAUSTED = code.ResourceExhausted,
	FAILED_PRECONDITION = code.FailedPrecondition,
	ABORTED = code.Aborted,
	OUT_OF_RANGE = code.OutOfRange,
	UNIMPLEMENTED = code.Unimplemented,
	INTERNAL = code.Internal,
	UNAVAILABLE = code.Unavailable,
	DATA_LOSS = code.DataLoss,
	UNAUTHENTICATED = code.Unauthenticated,
}

do	--reverse map
	local tmp = {}
	for k, v in pairs(M) do
		tmp[k] = v
	end
	for k, v in pairs(tmp) do
		M[v] = k
	end
end

return M