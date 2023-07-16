local pb     = require "pb"
local protoc = require "protoc"
local assert = assert
local P = protoc:new()

assert(P:load([[
syntax = "proto3";
package mvccpb;

message KeyValue {
  // key is the key in bytes. An empty key is not allowed.
  bytes key = 1;
  // create_revision is the revision of last creation on this key.
  int64 create_revision = 2;
  // mod_revision is the revision of last modification on this key.
  int64 mod_revision = 3;
  // version is the version of the key. A deletion resets
  // the version to zero and any modification of the key
  // increases its version.
  int64 version = 4;
  // value is the value held by the key, in bytes.
  bytes value = 5;
  // lease is the ID of the lease that attached to key.
  // When the attached lease expires, the key will be deleted.
  // If lease is 0, then no lease is attached to the key.
  int64 lease = 6;
}

message Event {
  enum EventType {
    PUT = 0;
    DELETE = 1;
  }
  // type is the kind of event. If type is a PUT, it indicates
  // new data has been stored to the key. If type is a DELETE,
  // it indicates the key was deleted.
  EventType type = 1;
  // kv holds the KeyValue for the event.
  // A PUT event contains current kv pair.
  // A PUT event with kv.Version=1 indicates the creation of a key.
  // A DELETE/EXPIRE event contains the deleted key with
  // its modification revision set to the revision of deletion.
  KeyValue kv = 2;

  // prev_kv holds the key-value pair before the event happens.
  KeyValue prev_kv = 3;
}
]], "etcd/api/mvccpb/kv.proto"))

assert(P:load([[
syntax = "proto3";
package authpb;

message UserAddOptions {
  bool no_password = 1;
};

// User is a single entry in the bucket authUsers
message User {
  bytes name = 1;
  bytes password = 2;
  repeated string roles = 3;
  UserAddOptions options = 4;
}

// Permission is a single entity
message Permission {
  enum Type {
    READ = 0;
    WRITE = 1;
    READWRITE = 2;
  }
  Type permType = 1;

  bytes key = 2;
  bytes range_end = 3;
}

// Role is a single entry in the bucket authRoles
message Role {
  bytes name = 1;

  repeated Permission keyPermission = 2;
}]], "etcd/api/authpb/auth.proto"))

assert(P:load([[
syntax = "proto3";
package etcdserverpb;

import "etcd/api/mvccpb/kv.proto";
import "etcd/api/authpb/auth.proto";

message ResponseHeader {
  // cluster_id is the ID of the cluster which sent the response.
  uint64 cluster_id = 1;
  // member_id is the ID of the member which sent the response.
  uint64 member_id = 2;
  // revision is the key-value store revision when the request was applied, and it's
  // unset (so 0) in case of calls not interacting with key-value store.
  // For watch progress responses, the header.revision indicates progress. All future events
  // received in this stream are guaranteed to have a higher revision number than the
  // header.revision number.
  int64 revision = 3;
  // raft_term is the raft term when the request was applied.
  uint64 raft_term = 4;
}

message RangeRequest {
  enum SortOrder {
    NONE = 0; // default, no sorting
    ASCEND = 1; // lowest target value first
    DESCEND = 2; // highest target value first
  }
  enum SortTarget {
    KEY = 0;
    VERSION = 1;
    CREATE = 2;
    MOD = 3;
    VALUE = 4;
  }

  // key is the first key for the range. If range_end is not given, the request only looks up key.
  bytes key = 1;
  // range_end is the upper bound on the requested range [key, range_end).
  // If range_end is '\0', the range is all keys >= key.
  // If range_end is key plus one (e.g., "aa"+1 == "ab", "a\xff"+1 == "b"),
  // then the range request gets all keys prefixed with key.
  // If both key and range_end are '\0', then the range request returns all keys.
  bytes range_end = 2;
  // limit is a limit on the number of keys returned for the request. When limit is set to 0,
  // it is treated as no limit.
  int64 limit = 3;
  // revision is the point-in-time of the key-value store to use for the range.
  // If revision is less or equal to zero, the range is over the newest key-value store.
  // If the revision has been compacted, ErrCompacted is returned as a response.
  int64 revision = 4;

  // sort_order is the order for returned sorted results.
  SortOrder sort_order = 5;

  // sort_target is the key-value field to use for sorting.
  SortTarget sort_target = 6;

  // serializable sets the range request to use serializable member-local reads.
  // Range requests are linearizable by default; linearizable requests have higher
  // latency and lower throughput than serializable requests but reflect the current
  // consensus of the cluster. For better performance, in exchange for possible stale reads,
  // a serializable range request is served locally without needing to reach consensus
  // with other nodes in the cluster.
  bool serializable = 7;

  // keys_only when set returns only the keys and not the values.
  bool keys_only = 8;

  // count_only when set returns only the count of the keys in the range.
  bool count_only = 9;

  // min_mod_revision is the lower bound for returned key mod revisions; all keys with
  // lesser mod revisions will be filtered away.
  int64 min_mod_revision = 10 [(versionpb.etcd_version_field)="3.1"];

  // max_mod_revision is the upper bound for returned key mod revisions; all keys with
  // greater mod revisions will be filtered away.
  int64 max_mod_revision = 11 [(versionpb.etcd_version_field)="3.1"];

  // min_create_revision is the lower bound for returned key create revisions; all keys with
  // lesser create revisions will be filtered away.
  int64 min_create_revision = 12 [(versionpb.etcd_version_field)="3.1"];

  // max_create_revision is the upper bound for returned key create revisions; all keys with
  // greater create revisions will be filtered away.
  int64 max_create_revision = 13 [(versionpb.etcd_version_field)="3.1"];
}

message RangeResponse {
  ResponseHeader header = 1;
  // kvs is the list of key-value pairs matched by the range request.
  // kvs is empty when count is requested.
  repeated mvccpb.KeyValue kvs = 2;
  // more indicates if there are more keys to return in the requested range.
  bool more = 3;
  // count is set to the number of keys within the range when requested.
  int64 count = 4;
}

message PutRequest {
  // key is the key, in bytes, to put into the key-value store.
  bytes key = 1;
  // value is the value, in bytes, to associate with the key in the key-value store.
  bytes value = 2;
  // lease is the lease ID to associate with the key in the key-value store. A lease
  // value of 0 indicates no lease.
  int64 lease = 3;

  // If prev_kv is set, etcd gets the previous key-value pair before changing it.
  // The previous key-value pair will be returned in the put response.
  bool prev_kv = 4;

  // If ignore_value is set, etcd updates the key using its current value.
  // Returns an error if the key does not exist.
  bool ignore_value = 5;

  // If ignore_lease is set, etcd updates the key using its current lease.
  // Returns an error if the key does not exist.
  bool ignore_lease = 6 [(versionpb.etcd_version_field)="3.2"];
}

message PutResponse {
  ResponseHeader header = 1;
  // if prev_kv is set in the request, the previous key-value pair will be returned.
  mvccpb.KeyValue prev_kv = 2 [(versionpb.etcd_version_field)="3.1"];
}
]]))


