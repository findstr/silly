local protoc = require "protoc"
local assert = assert
local p = protoc:new()

assert(p:load([[
// Protocol Buffers - Google's data interchange format
// Copyright 2008 Google Inc.  All rights reserved.
// https://developers.google.com/protocol-buffers/
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Author: kenton@google.com (Kenton Varda)
//  Based on original Protocol Buffers design by
//  Sanjay Ghemawat, Jeff Dean, and others.
//
// The messages in this file describe the definitions found in .proto files.
// A valid .proto file can be translated directly to a FileDescriptorProto
// without any other information (e.g. without reading its imports).

syntax = "proto2";

package google.protobuf;

option go_package = "google.golang.org/protobuf/types/descriptorpb";
option java_package = "com.google.protobuf";
option java_outer_classname = "DescriptorProtos";
option csharp_namespace = "Google.Protobuf.Reflection";
option objc_class_prefix = "GPB";
option cc_enable_arenas = true;

// descriptor.proto must be optimized for speed because reflection-based
// algorithms don't work during bootstrapping.
option optimize_for = SPEED;

// The protocol compiler can output a FileDescriptorSet containing the .proto
// files it parses.
message FileDescriptorSet {
  repeated FileDescriptorProto file = 1;
}

// The full set of known editions.
enum Edition {
  // A placeholder for an unknown edition value.
  EDITION_UNKNOWN = 0;

  // A placeholder edition for specifying default behaviors *before* a feature
  // was first introduced.  This is effectively an "infinite past".
  EDITION_LEGACY = 900;

  // Legacy syntax "editions".  These pre-date editions, but behave much like
  // distinct editions.  These can't be used to specify the edition of proto
  // files, but feature definitions must supply proto2/proto3 defaults for
  // backwards compatibility.
  EDITION_PROTO2 = 998;
  EDITION_PROTO3 = 999;

  // Editions that have been released.  The specific values are arbitrary and
  // should not be depended on, but they will always be time-ordered for easy
  // comparison.
  EDITION_2023 = 1000;
  EDITION_2024 = 1001;

  // Placeholder editions for testing feature resolution.  These should not be
  // used or relyed on outside of tests.
  EDITION_1_TEST_ONLY = 1;
  EDITION_2_TEST_ONLY = 2;
  EDITION_99997_TEST_ONLY = 99997;
  EDITION_99998_TEST_ONLY = 99998;
  EDITION_99999_TEST_ONLY = 99999;

  // Placeholder for specifying unbounded edition support.  This should only
  // ever be used by plugins that can expect to never require any changes to
  // support a new edition.
  EDITION_MAX = 0x7FFFFFFF;
}

// Describes a complete .proto file.
message FileDescriptorProto {
  optional string name = 1;     // file name, relative to root of source tree
  optional string package = 2;  // e.g. "foo", "foo.bar", etc.

  // Names of files imported by this file.
  repeated string dependency = 3;
  // Indexes of the public imported files in the dependency list above.
  repeated int32 public_dependency = 10;
  // Indexes of the weak imported files in the dependency list.
  // For Google-internal migration only. Do not use.
  repeated int32 weak_dependency = 11;

  // All top-level definitions in this file.
  repeated DescriptorProto message_type = 4;
  repeated EnumDescriptorProto enum_type = 5;
  repeated ServiceDescriptorProto service = 6;
  repeated FieldDescriptorProto extension = 7;

  optional FileOptions options = 8;

  // This field contains optional information about the original source code.
  // You may safely remove this entire field without harming runtime
  // functionality of the descriptors -- the information is needed only by
  // development tools.
  optional SourceCodeInfo source_code_info = 9;

  // The syntax of the proto file.
  // The supported values are "proto2", "proto3", and "editions".
  //
  // If `edition` is present, this value must be "editions".
  optional string syntax = 12;

  // The edition of the proto file.
  optional Edition edition = 14;
}

// Describes a message type.
message DescriptorProto {
  optional string name = 1;

  repeated FieldDescriptorProto field = 2;
  repeated FieldDescriptorProto extension = 6;

  repeated DescriptorProto nested_type = 3;
  repeated EnumDescriptorProto enum_type = 4;

  message ExtensionRange {
    optional int32 start = 1;  // Inclusive.
    optional int32 end = 2;    // Exclusive.

    optional ExtensionRangeOptions options = 3;
  }
  repeated ExtensionRange extension_range = 5;

  repeated OneofDescriptorProto oneof_decl = 8;

  optional MessageOptions options = 7;

  // Range of reserved tag numbers. Reserved tag numbers may not be used by
  // fields or extension ranges in the same message. Reserved ranges may
  // not overlap.
  message ReservedRange {
    optional int32 start = 1;  // Inclusive.
    optional int32 end = 2;    // Exclusive.
  }
  repeated ReservedRange reserved_range = 9;
  // Reserved field names, which may not be used by fields in the same message.
  // A given name may only be reserved once.
  repeated string reserved_name = 10;
}

message ExtensionRangeOptions {
  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  message Declaration {
    // The extension number declared within the extension range.
    optional int32 number = 1;

    // The fully-qualified name of the extension field. There must be a leading
    // dot in front of the full name.
    optional string full_name = 2;

    // The fully-qualified type name of the extension field. Unlike
    // Metadata.type, Declaration.type must have a leading dot for messages
    // and enums.
    optional string type = 3;

    // If true, indicates that the number is reserved in the extension range,
    // and any extension field with the number will fail to compile. Set this
    // when a declared extension field is deleted.
    optional bool reserved = 5;

    // If true, indicates that the extension must be defined as repeated.
    // Otherwise the extension must be defined as optional.
    optional bool repeated = 6;

    reserved 4;  // removed is_repeated
  }

  // For external users: DO NOT USE. We are in the process of open sourcing
  // extension declaration and executing internal cleanups before it can be
  // used externally.
  repeated Declaration declaration = 2 [retention = RETENTION_SOURCE];

  // Any features defined in the specific edition.
  optional FeatureSet features = 50;

  // The verification state of the extension range.
  enum VerificationState {
    // All the extensions of the range must be declared.
    DECLARATION = 0;
    UNVERIFIED = 1;
  }

  // The verification state of the range.
  // TODO: flip the default to DECLARATION once all empty ranges
  // are marked as UNVERIFIED.
  optional VerificationState verification = 3
      [default = UNVERIFIED, retention = RETENTION_SOURCE];

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;
}

// Describes a field within a message.
message FieldDescriptorProto {
  enum Type {
    // 0 is reserved for errors.
    // Order is weird for historical reasons.
    TYPE_DOUBLE = 1;
    TYPE_FLOAT = 2;
    // Not ZigZag encoded.  Negative numbers take 10 bytes.  Use TYPE_SINT64 if
    // negative values are likely.
    TYPE_INT64 = 3;
    TYPE_UINT64 = 4;
    // Not ZigZag encoded.  Negative numbers take 10 bytes.  Use TYPE_SINT32 if
    // negative values are likely.
    TYPE_INT32 = 5;
    TYPE_FIXED64 = 6;
    TYPE_FIXED32 = 7;
    TYPE_BOOL = 8;
    TYPE_STRING = 9;
    // Tag-delimited aggregate.
    // Group type is deprecated and not supported after google.protobuf. However, Proto3
    // implementations should still be able to parse the group wire format and
    // treat group fields as unknown fields.  In Editions, the group wire format
    // can be enabled via the `message_encoding` feature.
    TYPE_GROUP = 10;
    TYPE_MESSAGE = 11;  // Length-delimited aggregate.

    // New in version 2.
    TYPE_BYTES = 12;
    TYPE_UINT32 = 13;
    TYPE_ENUM = 14;
    TYPE_SFIXED32 = 15;
    TYPE_SFIXED64 = 16;
    TYPE_SINT32 = 17;  // Uses ZigZag encoding.
    TYPE_SINT64 = 18;  // Uses ZigZag encoding.
  }

  enum Label {
    // 0 is reserved for errors
    LABEL_OPTIONAL = 1;
    LABEL_REPEATED = 3;
    // The required label is only allowed in google.protobuf.  In proto3 and Editions
    // it's explicitly prohibited.  In Editions, the `field_presence` feature
    // can be used to get this behavior.
    LABEL_REQUIRED = 2;
  }

  optional string name = 1;
  optional int32 number = 3;
  optional Label label = 4;

  // If type_name is set, this need not be set.  If both this and type_name
  // are set, this must be one of TYPE_ENUM, TYPE_MESSAGE or TYPE_GROUP.
  optional Type type = 5;

  // For message and enum types, this is the name of the type.  If the name
  // starts with a '.', it is fully-qualified.  Otherwise, C++-like scoping
  // rules are used to find the type (i.e. first the nested types within this
  // message are searched, then within the parent, on up to the root
  // namespace).
  optional string type_name = 6;

  // For extensions, this is the name of the type being extended.  It is
  // resolved in the same manner as type_name.
  optional string extendee = 2;

  // For numeric types, contains the original text representation of the value.
  // For booleans, "true" or "false".
  // For strings, contains the default text contents (not escaped in any way).
  // For bytes, contains the C escaped value.  All bytes >= 128 are escaped.
  optional string default_value = 7;

  // If set, gives the index of a oneof in the containing type's oneof_decl
  // list.  This field is a member of that oneof.
  optional int32 oneof_index = 9;

  // JSON name of this field. The value is set by protocol compiler. If the
  // user has set a "json_name" option on this field, that option's value
  // will be used. Otherwise, it's deduced from the field's name by converting
  // it to camelCase.
  optional string json_name = 10;

  optional FieldOptions options = 8;

  // If true, this is a proto3 "optional". When a proto3 field is optional, it
  // tracks presence regardless of field type.
  //
  // When proto3_optional is true, this field must belong to a oneof to signal
  // to old proto3 clients that presence is tracked for this field. This oneof
  // is known as a "synthetic" oneof, and this field must be its sole member
  // (each proto3 optional field gets its own synthetic oneof). Synthetic oneofs
  // exist in the descriptor only, and do not generate any API. Synthetic oneofs
  // must be ordered after all "real" oneofs.
  //
  // For message fields, proto3_optional doesn't create any semantic change,
  // since non-repeated message fields always track presence. However it still
  // indicates the semantic detail of whether the user wrote "optional" or not.
  // This can be useful for round-tripping the .proto file. For consistency we
  // give message fields a synthetic oneof also, even though it is not required
  // to track presence. This is especially important because the parser can't
  // tell if a field is a message or an enum, so it must always create a
  // synthetic oneof.
  //
  // Proto2 optional fields do not set this flag, because they already indicate
  // optional with `LABEL_OPTIONAL`.
  optional bool proto3_optional = 17;
}

// Describes a oneof.
message OneofDescriptorProto {
  optional string name = 1;
  optional OneofOptions options = 2;
}

// Describes an enum type.
message EnumDescriptorProto {
  optional string name = 1;

  repeated EnumValueDescriptorProto value = 2;

  optional EnumOptions options = 3;

  // Range of reserved numeric values. Reserved values may not be used by
  // entries in the same enum. Reserved ranges may not overlap.
  //
  // Note that this is distinct from DescriptorProto.ReservedRange in that it
  // is inclusive such that it can appropriately represent the entire int32
  // domain.
  message EnumReservedRange {
    optional int32 start = 1;  // Inclusive.
    optional int32 end = 2;    // Inclusive.
  }

  // Range of reserved numeric values. Reserved numeric values may not be used
  // by enum values in the same enum declaration. Reserved ranges may not
  // overlap.
  repeated EnumReservedRange reserved_range = 4;

  // Reserved enum value names, which may not be reused. A given name may only
  // be reserved once.
  repeated string reserved_name = 5;
}

// Describes a value within an enum.
message EnumValueDescriptorProto {
  optional string name = 1;
  optional int32 number = 2;

  optional EnumValueOptions options = 3;
}

// Describes a service.
message ServiceDescriptorProto {
  optional string name = 1;
  repeated MethodDescriptorProto method = 2;

  optional ServiceOptions options = 3;
}

// Describes a method of a service.
message MethodDescriptorProto {
  optional string name = 1;

  // Input and output type names.  These are resolved in the same way as
  // FieldDescriptorProto.type_name, but must refer to a message type.
  optional string input_type = 2;
  optional string output_type = 3;

  optional MethodOptions options = 4;

  // Identifies if client streams multiple client messages
  optional bool client_streaming = 5 [default = false];
  // Identifies if server streams multiple server messages
  optional bool server_streaming = 6 [default = false];
}

// ===================================================================
// Options

// Each of the definitions above may have "options" attached.  These are
// just annotations which may cause code to be generated slightly differently
// or may contain hints for code that manipulates protocol messages.
//
// Clients may define custom options as extensions of the *Options messages.
// These extensions may not yet be known at parsing time, so the parser cannot
// store the values in them.  Instead it stores them in a field in the *Options
// message called uninterpreted_option. This field must have the same name
// across all *Options messages. We then use this field to populate the
// extensions when we build a descriptor, at which point all protos have been
// parsed and so all extensions are known.
//
// Extension numbers for custom options may be chosen as follows:
// * For options which will only be used within a single application or
//   organization, or for experimental options, use field numbers 50000
//   through 99999.  It is up to you to ensure that you do not use the
//   same number for multiple options.
// * For options which will be published and used publicly by multiple
//   independent entities, e-mail protobuf-global-extension-registry@google.com
//   to reserve extension numbers. Simply provide your project name (e.g.
//   Objective-C plugin) and your project website (if available) -- there's no
//   need to explain how you intend to use them. Usually you only need one
//   extension number. You can declare multiple options with only one extension
//   number by putting them in a sub-message. See the Custom Options section of
//   the docs for examples:
//   https://developers.google.com/protocol-buffers/docs/proto#options
//   If this turns out to be popular, a web service will be set up
//   to automatically assign option numbers.

message FileOptions {

  // Sets the Java package where classes generated from this .proto will be
  // placed.  By default, the proto package is used, but this is often
  // inappropriate because proto packages do not normally start with backwards
  // domain names.
  optional string java_package = 1;

  // Controls the name of the wrapper Java class generated for the .proto file.
  // That class will always contain the .proto file's getDescriptor() method as
  // well as any top-level extensions defined in the .proto file.
  // If java_multiple_files is disabled, then all the other classes from the
  // .proto file will be nested inside the single wrapper outer class.
  optional string java_outer_classname = 8;

  // If enabled, then the Java code generator will generate a separate .java
  // file for each top-level message, enum, and service defined in the .proto
  // file.  Thus, these types will *not* be nested inside the wrapper class
  // named by java_outer_classname.  However, the wrapper class will still be
  // generated to contain the file's getDescriptor() method as well as any
  // top-level extensions defined in the file.
  optional bool java_multiple_files = 10 [default = false];

  // This option does nothing.
  optional bool java_generate_equals_and_hash = 20 [deprecated=true];

  // A proto2 file can set this to true to opt in to UTF-8 checking for Java,
  // which will throw an exception if invalid UTF-8 is parsed from the wire or
  // assigned to a string field.
  //
  // TODO: clarify exactly what kinds of field types this option
  // applies to, and update these docs accordingly.
  //
  // Proto3 files already perform these checks. Setting the option explicitly to
  // false has no effect: it cannot be used to opt proto3 files out of UTF-8
  // checks.
  optional bool java_string_check_utf8 = 27 [default = false];

  // Generated classes can be optimized for speed or code size.
  enum OptimizeMode {
    SPEED = 1;         // Generate complete code for parsing, serialization,
                       // etc.
    CODE_SIZE = 2;     // Use ReflectionOps to implement these methods.
    LITE_RUNTIME = 3;  // Generate code using MessageLite and the lite runtime.
  }
  optional OptimizeMode optimize_for = 9 [default = SPEED];

  // Sets the Go package where structs generated from this .proto will be
  // placed. If omitted, the Go package will be derived from the following:
  //   - The basename of the package import path, if provided.
  //   - Otherwise, the package statement in the .proto file, if present.
  //   - Otherwise, the basename of the .proto file, without extension.
  optional string go_package = 11;

  // Should generic services be generated in each language?  "Generic" services
  // are not specific to any particular RPC system.  They are generated by the
  // main code generators in each language (without additional plugins).
  // Generic services were the only kind of service generation supported by
  // early versions of google.protobuf.
  //
  // Generic services are now considered deprecated in favor of using plugins
  // that generate code specific to your particular RPC system.  Therefore,
  // these default to false.  Old code which depends on generic services should
  // explicitly set them to true.
  optional bool cc_generic_services = 16 [default = false];
  optional bool java_generic_services = 17 [default = false];
  optional bool py_generic_services = 18 [default = false];
  reserved 42;  // removed php_generic_services

  // Is this file deprecated?
  // Depending on the target platform, this can emit Deprecated annotations
  // for everything in the file, or it will be completely ignored; in the very
  // least, this is a formalization for deprecating files.
  optional bool deprecated = 23 [default = false];

  // Enables the use of arenas for the proto messages in this file. This applies
  // only to generated classes for C++.
  optional bool cc_enable_arenas = 31 [default = true];

  // Sets the objective c class prefix which is prepended to all objective c
  // generated classes from this .proto. There is no default.
  optional string objc_class_prefix = 36;

  // Namespace for generated classes; defaults to the package.
  optional string csharp_namespace = 37;

  // By default Swift generators will take the proto package and CamelCase it
  // replacing '.' with underscore and use that to prefix the types/symbols
  // defined. When this options is provided, they will use this value instead
  // to prefix the types/symbols defined.
  optional string swift_prefix = 39;

  // Sets the php class prefix which is prepended to all php generated classes
  // from this .proto. Default is empty.
  optional string php_class_prefix = 40;

  // Use this option to change the namespace of php generated classes. Default
  // is empty. When this option is empty, the package name will be used for
  // determining the namespace.
  optional string php_namespace = 41;

  // Use this option to change the namespace of php generated metadata classes.
  // Default is empty. When this option is empty, the proto file name will be
  // used for determining the namespace.
  optional string php_metadata_namespace = 44;

  // Use this option to change the package of ruby generated classes. Default
  // is empty. When this option is not set, the package name will be used for
  // determining the ruby package.
  optional string ruby_package = 45;

  // Any features defined in the specific edition.
  optional FeatureSet features = 50;

  // The parser stores options it doesn't recognize here.
  // See the documentation for the "Options" section above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message.
  // See the documentation for the "Options" section above.
  extensions 1000 to max;

  reserved 38;
}

message MessageOptions {
  // Set true to use the old proto1 MessageSet wire format for extensions.
  // This is provided for backwards-compatibility with the MessageSet wire
  // format.  You should not use this for any other reason:  It's less
  // efficient, has fewer features, and is more complicated.
  //
  // The message must be defined exactly as follows:
  //   message Foo {
  //     option message_set_wire_format = true;
  //     extensions 4 to max;
  //   }
  // Note that the message cannot have any defined fields; MessageSets only
  // have extensions.
  //
  // All extensions of your type must be singular messages; e.g. they cannot
  // be int32s, enums, or repeated messages.
  //
  // Because this is an option, the above two restrictions are not enforced by
  // the protocol compiler.
  optional bool message_set_wire_format = 1 [default = false];

  // Disables the generation of the standard "descriptor()" accessor, which can
  // conflict with a field of the same name.  This is meant to make migration
  // from proto1 easier; new code should avoid fields named "descriptor".
  optional bool no_standard_descriptor_accessor = 2 [default = false];

  // Is this message deprecated?
  // Depending on the target platform, this can emit Deprecated annotations
  // for the message, or it will be completely ignored; in the very least,
  // this is a formalization for deprecating messages.
  optional bool deprecated = 3 [default = false];

  reserved 4, 5, 6;

  // Whether the message is an automatically generated map entry type for the
  // maps field.
  //
  // For maps fields:
  //     map<KeyType, ValueType> map_field = 1;
  // The parsed descriptor looks like:
  //     message MapFieldEntry {
  //         option map_entry = true;
  //         optional KeyType key = 1;
  //         optional ValueType value = 2;
  //     }
  //     repeated MapFieldEntry map_field = 1;
  //
  // Implementations may choose not to generate the map_entry=true message, but
  // use a native map in the target language to hold the keys and values.
  // The reflection APIs in such implementations still need to work as
  // if the field is a repeated message field.
  //
  // NOTE: Do not set the option in .proto files. Always use the maps syntax
  // instead. The option should only be implicitly set by the proto compiler
  // parser.
  optional bool map_entry = 7;

  reserved 8;  // javalite_serializable
  reserved 9;  // javanano_as_lite

  // Enable the legacy handling of JSON field name conflicts.  This lowercases
  // and strips underscored from the fields before comparison in proto3 only.
  // The new behavior takes `json_name` into account and applies to proto2 as
  // well.
  //
  // This should only be used as a temporary measure against broken builds due
  // to the change in behavior for JSON field name conflicts.
  //
  // TODO This is legacy behavior we plan to remove once downstream
  // teams have had time to migrate.
  optional bool deprecated_legacy_json_field_conflicts = 11 [deprecated = true];

  // Any features defined in the specific edition.
  optional FeatureSet features = 12;

  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;
}

message FieldOptions {
  // The ctype option instructs the C++ code generator to use a different
  // representation of the field than it normally would.  See the specific
  // options below.  This option is only implemented to support use of
  // [ctype=CORD] and [ctype=STRING] (the default) on non-repeated fields of
  // type "bytes" in the open source release -- sorry, we'll try to include
  // other types in a future version!
  optional CType ctype = 1 [default = STRING];
  enum CType {
    // Default mode.
    STRING = 0;

    // The option [ctype=CORD] may be applied to a non-repeated field of type
    // "bytes". It indicates that in C++, the data should be stored in a Cord
    // instead of a string.  For very large strings, this may reduce memory
    // fragmentation. It may also allow better performance when parsing from a
    // Cord, or when parsing with aliasing enabled, as the parsed Cord may then
    // alias the original buffer.
    CORD = 1;

    STRING_PIECE = 2;
  }
  // The packed option can be enabled for repeated primitive fields to enable
  // a more efficient representation on the wire. Rather than repeatedly
  // writing the tag and type for each element, the entire array is encoded as
  // a single length-delimited blob. In proto3, only explicit setting it to
  // false will avoid using packed encoding.  This option is prohibited in
  // Editions, but the `repeated_field_encoding` feature can be used to control
  // the behavior.
  optional bool packed = 2;

  // The jstype option determines the JavaScript type used for values of the
  // field.  The option is permitted only for 64 bit integral and fixed types
  // (int64, uint64, sint64, fixed64, sfixed64).  A field with jstype JS_STRING
  // is represented as JavaScript string, which avoids loss of precision that
  // can happen when a large value is converted to a floating point JavaScript.
  // Specifying JS_NUMBER for the jstype causes the generated JavaScript code to
  // use the JavaScript "number" type.  The behavior of the default option
  // JS_NORMAL is implementation dependent.
  //
  // This option is an enum to permit additional types to be added, e.g.
  // goog.math.Integer.
  optional JSType jstype = 6 [default = JS_NORMAL];
  enum JSType {
    // Use the default type.
    JS_NORMAL = 0;

    // Use JavaScript strings.
    JS_STRING = 1;

    // Use JavaScript numbers.
    JS_NUMBER = 2;
  }

  // Should this field be parsed lazily?  Lazy applies only to message-type
  // fields.  It means that when the outer message is initially parsed, the
  // inner message's contents will not be parsed but instead stored in encoded
  // form.  The inner message will actually be parsed when it is first accessed.
  //
  // This is only a hint.  Implementations are free to choose whether to use
  // eager or lazy parsing regardless of the value of this option.  However,
  // setting this option true suggests that the protocol author believes that
  // using lazy parsing on this field is worth the additional bookkeeping
  // overhead typically needed to implement it.
  //
  // This option does not affect the public interface of any generated code;
  // all method signatures remain the same.  Furthermore, thread-safety of the
  // interface is not affected by this option; const methods remain safe to
  // call from multiple threads concurrently, while non-const methods continue
  // to require exclusive access.
  //
  // Note that lazy message fields are still eagerly verified to check
  // ill-formed wireformat or missing required fields. Calling IsInitialized()
  // on the outer message would fail if the inner message has missing required
  // fields. Failed verification would result in parsing failure (except when
  // uninitialized messages are acceptable).
  optional bool lazy = 5 [default = false];

  // unverified_lazy does no correctness checks on the byte stream. This should
  // only be used where lazy with verification is prohibitive for performance
  // reasons.
  optional bool unverified_lazy = 15 [default = false];

  // Is this field deprecated?
  // Depending on the target platform, this can emit Deprecated annotations
  // for accessors, or it will be completely ignored; in the very least, this
  // is a formalization for deprecating fields.
  optional bool deprecated = 3 [default = false];

  // For Google-internal migration only. Do not use.
  optional bool weak = 10 [default = false];

  // Indicate that the field value should not be printed out when using debug
  // formats, e.g. when the field contains sensitive credentials.
  optional bool debug_redact = 16 [default = false];

  // If set to RETENTION_SOURCE, the option will be omitted from the binary.
  // Note: as of January 2023, support for this is in progress and does not yet
  // have an effect (b/264593489).
  enum OptionRetention {
    RETENTION_UNKNOWN = 0;
    RETENTION_RUNTIME = 1;
    RETENTION_SOURCE = 2;
  }

  optional OptionRetention retention = 17;

  // This indicates the types of entities that the field may apply to when used
  // as an option. If it is unset, then the field may be freely used as an
  // option on any kind of entity. Note: as of January 2023, support for this is
  // in progress and does not yet have an effect (b/264593489).
  enum OptionTargetType {
    TARGET_TYPE_UNKNOWN = 0;
    TARGET_TYPE_FILE = 1;
    TARGET_TYPE_EXTENSION_RANGE = 2;
    TARGET_TYPE_MESSAGE = 3;
    TARGET_TYPE_FIELD = 4;
    TARGET_TYPE_ONEOF = 5;
    TARGET_TYPE_ENUM = 6;
    TARGET_TYPE_ENUM_ENTRY = 7;
    TARGET_TYPE_SERVICE = 8;
    TARGET_TYPE_METHOD = 9;
  }

  repeated OptionTargetType targets = 19;

  message EditionDefault {
    optional Edition edition = 3;
    optional string value = 2;  // Textproto value.
  }
  repeated EditionDefault edition_defaults = 20;

  // Any features defined in the specific edition.
  optional FeatureSet features = 21;

  // Information about the support window of a feature.
  message FeatureSupport {
    // The edition that this feature was first available in.  In editions
    // earlier than this one, the default assigned to EDITION_LEGACY will be
    // used, and proto files will not be able to override it.
    optional Edition edition_introduced = 1;

    // The edition this feature becomes deprecated in.  Using this after this
    // edition may trigger warnings.
    optional Edition edition_deprecated = 2;

    // The deprecation warning text if this feature is used after the edition it
    // was marked deprecated in.
    optional string deprecation_warning = 3;

    // The edition this feature is no longer available in.  In editions after
    // this one, the last default assigned will be used, and proto files will
    // not be able to override it.
    optional Edition edition_removed = 4;
  }
  optional FeatureSupport feature_support = 22;

  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;

  reserved 4;   // removed jtype
  reserved 18;  // reserve target, target_obsolete_do_not_use
}

message OneofOptions {
  // Any features defined in the specific edition.
  optional FeatureSet features = 1;

  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;
}

message EnumOptions {

  // Set this option to true to allow mapping different tag names to the same
  // value.
  optional bool allow_alias = 2;

  // Is this enum deprecated?
  // Depending on the target platform, this can emit Deprecated annotations
  // for the enum, or it will be completely ignored; in the very least, this
  // is a formalization for deprecating enums.
  optional bool deprecated = 3 [default = false];

  reserved 5;  // javanano_as_lite

  // Enable the legacy handling of JSON field name conflicts.  This lowercases
  // and strips underscored from the fields before comparison in proto3 only.
  // The new behavior takes `json_name` into account and applies to proto2 as
  // well.
  // TODO Remove this legacy behavior once downstream teams have
  // had time to migrate.
  optional bool deprecated_legacy_json_field_conflicts = 6 [deprecated = true];

  // Any features defined in the specific edition.
  optional FeatureSet features = 7;

  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;
}

message EnumValueOptions {
  // Is this enum value deprecated?
  // Depending on the target platform, this can emit Deprecated annotations
  // for the enum value, or it will be completely ignored; in the very least,
  // this is a formalization for deprecating enum values.
  optional bool deprecated = 1 [default = false];

  // Any features defined in the specific edition.
  optional FeatureSet features = 2;

  // Indicate that fields annotated with this enum value should not be printed
  // out when using debug formats, e.g. when the field contains sensitive
  // credentials.
  optional bool debug_redact = 3 [default = false];

  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;
}

message ServiceOptions {

  // Any features defined in the specific edition.
  optional FeatureSet features = 34;

  // Note:  Field numbers 1 through 32 are reserved for Google's internal RPC
  //   framework.  We apologize for hoarding these numbers to ourselves, but
  //   we were already using them long before we decided to release Protocol
  //   Buffers.

  // Is this service deprecated?
  // Depending on the target platform, this can emit Deprecated annotations
  // for the service, or it will be completely ignored; in the very least,
  // this is a formalization for deprecating services.
  optional bool deprecated = 33 [default = false];

  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;
}

message MethodOptions {

  // Note:  Field numbers 1 through 32 are reserved for Google's internal RPC
  //   framework.  We apologize for hoarding these numbers to ourselves, but
  //   we were already using them long before we decided to release Protocol
  //   Buffers.

  // Is this method deprecated?
  // Depending on the target platform, this can emit Deprecated annotations
  // for the method, or it will be completely ignored; in the very least,
  // this is a formalization for deprecating methods.
  optional bool deprecated = 33 [default = false];

  // Is this method side-effect-free (or safe in HTTP parlance), or idempotent,
  // or neither? HTTP based RPC implementation may choose GET verb for safe
  // methods, and PUT verb for idempotent methods instead of the default POST.
  enum IdempotencyLevel {
    IDEMPOTENCY_UNKNOWN = 0;
    NO_SIDE_EFFECTS = 1;  // implies idempotent
    IDEMPOTENT = 2;       // idempotent, but may have side effects
  }
  optional IdempotencyLevel idempotency_level = 34
      [default = IDEMPOTENCY_UNKNOWN];

  // Any features defined in the specific edition.
  optional FeatureSet features = 35;

  // The parser stores options it doesn't recognize here. See above.
  repeated UninterpretedOption uninterpreted_option = 999;

  // Clients can define custom options in extensions of this message. See above.
  extensions 1000 to max;
}

// A message representing a option the parser does not recognize. This only
// appears in options protos created by the compiler::Parser class.
// DescriptorPool resolves these when building Descriptor objects. Therefore,
// options protos in descriptor objects (e.g. returned by Descriptor::options(),
// or produced by Descriptor::CopyTo()) will never have UninterpretedOptions
// in them.
message UninterpretedOption {
  // The name of the uninterpreted option.  Each string represents a segment in
  // a dot-separated name.  is_extension is true iff a segment represents an
  // extension (denoted with parentheses in options specs in .proto files).
  // E.g.,{ ["foo", false], ["bar.baz", true], ["moo", false] } represents
  // "foo.(bar.baz).moo".
  message NamePart {
    required string name_part = 1;
    required bool is_extension = 2;
  }
  repeated NamePart name = 2;

  // The value of the uninterpreted option, in whatever type the tokenizer
  // identified it as during parsing. Exactly one of these should be set.
  optional string identifier_value = 3;
  optional uint64 positive_int_value = 4;
  optional int64 negative_int_value = 5;
  optional double double_value = 6;
  optional bytes string_value = 7;
  optional string aggregate_value = 8;
}

// ===================================================================
// Features

// TODO Enums in C++ gencode (and potentially other languages) are
// not well scoped.  This means that each of the feature enums below can clash
// with each other.  The short names we've chosen maximize call-site
// readability, but leave us very open to this scenario.  A future feature will
// be designed and implemented to handle this, hopefully before we ever hit a
// conflict here.
message FeatureSet {
  enum FieldPresence {
    FIELD_PRESENCE_UNKNOWN = 0;
    EXPLICIT = 1;
    IMPLICIT = 2;
    LEGACY_REQUIRED = 3;
  }
  optional FieldPresence field_presence = 1 [
    retention = RETENTION_RUNTIME,
    targets = TARGET_TYPE_FIELD,
    targets = TARGET_TYPE_FILE,
    // TODO Enable this in google3 once protoc rolls out.
    feature_support = {
      edition_introduced: EDITION_2023,
    },
    edition_defaults = { edition: EDITION_PROTO2, value: "EXPLICIT" },
    edition_defaults = { edition: EDITION_PROTO3, value: "IMPLICIT" },
    edition_defaults = { edition: EDITION_2023, value: "EXPLICIT" }
  ];

  enum EnumType {
    ENUM_TYPE_UNKNOWN = 0;
    OPEN = 1;
    CLOSED = 2;
  }
  optional EnumType enum_type = 2 [
    retention = RETENTION_RUNTIME,
    targets = TARGET_TYPE_ENUM,
    targets = TARGET_TYPE_FILE,
    // TODO Enable this in google3 once protoc rolls out.
    feature_support = {
      edition_introduced: EDITION_2023,
    },
    edition_defaults = { edition: EDITION_PROTO2, value: "CLOSED" },
    edition_defaults = { edition: EDITION_PROTO3, value: "OPEN" }
  ];

  enum RepeatedFieldEncoding {
    REPEATED_FIELD_ENCODING_UNKNOWN = 0;
    PACKED = 1;
    EXPANDED = 2;
  }
  optional RepeatedFieldEncoding repeated_field_encoding = 3 [
    retention = RETENTION_RUNTIME,
    targets = TARGET_TYPE_FIELD,
    targets = TARGET_TYPE_FILE,
    // TODO Enable this in google3 once protoc rolls out.
    feature_support = {
      edition_introduced: EDITION_2023,
    },
    edition_defaults = { edition: EDITION_PROTO2, value: "EXPANDED" },
    edition_defaults = { edition: EDITION_PROTO3, value: "PACKED" }
  ];

  enum Utf8Validation {
    UTF8_VALIDATION_UNKNOWN = 0;
    VERIFY = 2;
    NONE = 3;
  }
  optional Utf8Validation utf8_validation = 4 [
    retention = RETENTION_RUNTIME,
    targets = TARGET_TYPE_FIELD,
    targets = TARGET_TYPE_FILE,
    // TODO Enable this in google3 once protoc rolls out.
    feature_support = {
      edition_introduced: EDITION_2023,
    },
    edition_defaults = { edition: EDITION_PROTO2, value: "NONE" },
    edition_defaults = { edition: EDITION_PROTO3, value: "VERIFY" }
  ];

  enum MessageEncoding {
    MESSAGE_ENCODING_UNKNOWN = 0;
    LENGTH_PREFIXED = 1;
    DELIMITED = 2;
  }
  optional MessageEncoding message_encoding = 5 [
    retention = RETENTION_RUNTIME,
    targets = TARGET_TYPE_FIELD,
    targets = TARGET_TYPE_FILE,
    // TODO Enable this in google3 once protoc rolls out.
    feature_support = {
      edition_introduced: EDITION_2023,
    },
    edition_defaults = { edition: EDITION_PROTO2, value: "LENGTH_PREFIXED" }
  ];

  enum JsonFormat {
    JSON_FORMAT_UNKNOWN = 0;
    ALLOW = 1;
    LEGACY_BEST_EFFORT = 2;
  }
  optional JsonFormat json_format = 6 [
    retention = RETENTION_RUNTIME,
    targets = TARGET_TYPE_MESSAGE,
    targets = TARGET_TYPE_ENUM,
    targets = TARGET_TYPE_FILE,
    // TODO Enable this in google3 once protoc rolls out.
    feature_support = {
      edition_introduced: EDITION_2023,
    },
    edition_defaults = { edition: EDITION_PROTO2, value: "LEGACY_BEST_EFFORT" },
    edition_defaults = { edition: EDITION_PROTO3, value: "ALLOW" }
  ];

  reserved 999;

  extensions 1000;  // for Protobuf C++
  extensions 1001;  // for Protobuf Java
  extensions 1002;  // for Protobuf Go

  extensions 9990;  // for deprecated Java Proto1

  extensions 9995 to 9999;  // For internal testing
  extensions 10000;         // for https://github.com/bufbuild/protobuf-es
}

// A compiled specification for the defaults of a set of features.  These
// messages are generated from FeatureSet extensions and can be used to seed
// feature resolution. The resolution with this object becomes a simple search
// for the closest matching edition, followed by proto merges.
message FeatureSetDefaults {
  // A map from every known edition with a unique set of defaults to its
  // defaults. Not all editions may be contained here.  For a given edition,
  // the defaults at the closest matching edition ordered at or before it should
  // be used.  This field must be in strict ascending order by edition.
  message FeatureSetEditionDefault {
    optional Edition edition = 3;

    // Defaults of features that can be overridden in this edition.
    optional FeatureSet overridable_features = 4;

    // Defaults of features that can't be overridden in this edition.
    optional FeatureSet fixed_features = 5;

    // TODO Deprecate and remove this field, which is just the
    // above two merged.
    optional FeatureSet features = 2;
  }
  repeated FeatureSetEditionDefault defaults = 1;

  // The minimum supported edition (inclusive) when this was constructed.
  // Editions before this will not have defaults.
  optional Edition minimum_edition = 4;

  // The maximum known edition (inclusive) when this was constructed. Editions
  // after this will not have reliable defaults.
  optional Edition maximum_edition = 5;
}

// ===================================================================
// Optional source code info

// Encapsulates information about the original source file from which a
// FileDescriptorProto was generated.
message SourceCodeInfo {
  // A Location identifies a piece of source code in a .proto file which
  // corresponds to a particular definition.  This information is intended
  // to be useful to IDEs, code indexers, documentation generators, and similar
  // tools.
  //
  // For example, say we have a file like:
  //   message Foo {
  //     optional string foo = 1;
  //   }
  // Let's look at just the field definition:
  //   optional string foo = 1;
  //   ^       ^^     ^^  ^  ^^^
  //   a       bc     de  f  ghi
  // We have the following locations:
  //   span   path               represents
  //   [a,i)  [ 4, 0, 2, 0 ]     The whole field definition.
  //   [a,b)  [ 4, 0, 2, 0, 4 ]  The label (optional).
  //   [c,d)  [ 4, 0, 2, 0, 5 ]  The type (string).
  //   [e,f)  [ 4, 0, 2, 0, 1 ]  The name (foo).
  //   [g,h)  [ 4, 0, 2, 0, 3 ]  The number (1).
  //
  // Notes:
  // - A location may refer to a repeated field itself (i.e. not to any
  //   particular index within it).  This is used whenever a set of elements are
  //   logically enclosed in a single code segment.  For example, an entire
  //   extend block (possibly containing multiple extension definitions) will
  //   have an outer location whose path refers to the "extensions" repeated
  //   field without an index.
  // - Multiple locations may have the same path.  This happens when a single
  //   logical declaration is spread out across multiple places.  The most
  //   obvious example is the "extend" block again -- there may be multiple
  //   extend blocks in the same scope, each of which will have the same path.
  // - A location's span is not always a subset of its parent's span.  For
  //   example, the "extendee" of an extension declaration appears at the
  //   beginning of the "extend" block and is shared by all extensions within
  //   the block.
  // - Just because a location's span is a subset of some other location's span
  //   does not mean that it is a descendant.  For example, a "group" defines
  //   both a type and a field in a single declaration.  Thus, the locations
  //   corresponding to the type and field and their components will overlap.
  // - Code which tries to interpret locations should probably be designed to
  //   ignore those that it doesn't understand, as more types of locations could
  //   be recorded in the future.
  repeated Location location = 1;
  message Location {
    // Identifies which part of the FileDescriptorProto was defined at this
    // location.
    //
    // Each element is a field number or an index.  They form a path from
    // the root FileDescriptorProto to the place where the definition appears.
    // For example, this path:
    //   [ 4, 3, 2, 7, 1 ]
    // refers to:
    //   file.message_type(3)  // 4, 3
    //       .field(7)         // 2, 7
    //       .name()           // 1
    // This is because FileDescriptorProto.message_type has field number 4:
    //   repeated DescriptorProto message_type = 4;
    // and DescriptorProto.field has field number 2:
    //   repeated FieldDescriptorProto field = 2;
    // and FieldDescriptorProto.name has field number 1:
    //   optional string name = 1;
    //
    // Thus, the above path gives the location of a field name.  If we removed
    // the last element:
    //   [ 4, 3, 2, 7 ]
    // this path refers to the whole field declaration (from the beginning
    // of the label to the terminating semicolon).
    repeated int32 path = 1 [packed = true];

    // Always has exactly three or four elements: start line, start column,
    // end line (optional, otherwise assumed same as start line), end column.
    // These are packed into a single field for efficiency.  Note that line
    // and column numbers are zero-based -- typically you will want to add
    // 1 to each before displaying to a user.
    repeated int32 span = 2 [packed = true];

    // If this SourceCodeInfo represents a complete declaration, these are any
    // comments appearing before and after the declaration which appear to be
    // attached to the declaration.
    //
    // A series of line comments appearing on consecutive lines, with no other
    // tokens appearing on those lines, will be treated as a single comment.
    //
    // leading_detached_comments will keep paragraphs of comments that appear
    // before (but not connected to) the current element. Each paragraph,
    // separated by empty lines, will be one comment element in the repeated
    // field.
    //
    // Only the comment content is provided; comment markers (e.g. //) are
    // stripped out.  For block comments, leading whitespace and an asterisk
    // will be stripped from the beginning of each line other than the first.
    // Newlines are included in the output.
    //
    // Examples:
    //
    //   optional int32 foo = 1;  // Comment attached to foo.
    //   // Comment attached to bar.
    //   optional int32 bar = 2;
    //
    //   optional string baz = 3;
    //   // Comment attached to baz.
    //   // Another line attached to baz.
    //
    //   // Comment attached to moo.
    //   //
    //   // Another line attached to moo.
    //   optional double moo = 4;
    //
    //   // Detached comment for corge. This is not leading or trailing comments
    //   // to moo or corge because there are blank lines separating it from
    //   // both.
    //
    //   // Detached comment for corge paragraph 2.
    //
    //   optional string corge = 5;
    //   /* Block comment attached
    //    * to corge.  Leading asterisks
    //    * will be removed. */
    //   /* Block comment attached to
    //    * grault. */
    //   optional int32 grault = 6;
    //
    //   // ignored detached comments.
    optional string leading_comments = 3;
    optional string trailing_comments = 4;
    repeated string leading_detached_comments = 6;
  }
}

// Describes the relationship between generated code and its original source
// file. A GeneratedCodeInfo message is associated with only one generated
// source file, but may contain references to different source .proto files.
message GeneratedCodeInfo {
  // An Annotation connects some span of text in generated code to an element
  // of its generating .proto file.
  repeated Annotation annotation = 1;
  message Annotation {
    // Identifies the element in the original source .proto file. This field
    // is formatted the same as SourceCodeInfo.Location.path.
    repeated int32 path = 1 [packed = true];

    // Identifies the filesystem path to the original source .proto.
    optional string source_file = 2;

    // Identifies the starting offset in bytes in the generated code
    // that relates to the identified object.
    optional int32 begin = 3;

    // Identifies the ending offset in bytes in the generated code that
    // relates to the identified object. The end offset should be one past
    // the last relevant byte (so the length of the text = end - begin).
    optional int32 end = 4;

    // Represents the identified object's effect on the element in the original
    // .proto file.
    enum Semantic {
      // There is no effect or the effect is indescribable.
      NONE = 0;
      // The element is set or otherwise mutated.
      SET = 1;
      // An alias to the element is returned.
      ALIAS = 2;
    }
    optional Semantic semantic = 5;
  }
}
]], "google/protobuf/descriptor.proto"))

assert(p:load([[
// Protocol Buffers for Go with Gadgets
//
// Copyright (c) 2013, The GoGo Authors. All rights reserved.
// http://github.com/gogo/protobuf
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

syntax = "proto2";
package gogoproto;

import "google/protobuf/descriptor.proto";

option java_package = "com.google.protobuf";
option java_outer_classname = "GoGoProtos";
option go_package = "github.com/gogo/protobuf/gogoproto";

extend google.protobuf.EnumOptions {
	optional bool goproto_enum_prefix = 62001;
	optional bool goproto_enum_stringer = 62021;
	optional bool enum_stringer = 62022;
	optional string enum_customname = 62023;
	optional bool enumdecl = 62024;
}

extend google.protobuf.EnumValueOptions {
	optional string enumvalue_customname = 66001;
}

extend google.protobuf.FileOptions {
	optional bool goproto_getters_all = 63001;
	optional bool goproto_enum_prefix_all = 63002;
	optional bool goproto_stringer_all = 63003;
	optional bool verbose_equal_all = 63004;
	optional bool face_all = 63005;
	optional bool gostring_all = 63006;
	optional bool populate_all = 63007;
	optional bool stringer_all = 63008;
	optional bool onlyone_all = 63009;

	optional bool equal_all = 63013;
	optional bool description_all = 63014;
	optional bool testgen_all = 63015;
	optional bool benchgen_all = 63016;
	optional bool marshaler_all = 63017;
	optional bool unmarshaler_all = 63018;
	optional bool stable_marshaler_all = 63019;

	optional bool sizer_all = 63020;

	optional bool goproto_enum_stringer_all = 63021;
	optional bool enum_stringer_all = 63022;

	optional bool unsafe_marshaler_all = 63023;
	optional bool unsafe_unmarshaler_all = 63024;

	optional bool goproto_extensions_map_all = 63025;
	optional bool goproto_unrecognized_all = 63026;
	optional bool gogoproto_import = 63027;
	optional bool protosizer_all = 63028;
	optional bool compare_all = 63029;
	optional bool typedecl_all = 63030;
	optional bool enumdecl_all = 63031;

	optional bool goproto_registration = 63032;
	optional bool messagename_all = 63033;

	optional bool goproto_sizecache_all = 63034;
	optional bool goproto_unkeyed_all = 63035;
}

extend google.protobuf.MessageOptions {
	optional bool goproto_getters = 64001;
	optional bool goproto_stringer = 64003;
	optional bool verbose_equal = 64004;
	optional bool face = 64005;
	optional bool gostring = 64006;
	optional bool populate = 64007;
	optional bool stringer = 67008;
	optional bool onlyone = 64009;

	optional bool equal = 64013;
	optional bool description = 64014;
	optional bool testgen = 64015;
	optional bool benchgen = 64016;
	optional bool marshaler = 64017;
	optional bool unmarshaler = 64018;
	optional bool stable_marshaler = 64019;

	optional bool sizer = 64020;

	optional bool unsafe_marshaler = 64023;
	optional bool unsafe_unmarshaler = 64024;

	optional bool goproto_extensions_map = 64025;
	optional bool goproto_unrecognized = 64026;

	optional bool protosizer = 64028;
	optional bool compare = 64029;

	optional bool typedecl = 64030;

	optional bool messagename = 64033;

	optional bool goproto_sizecache = 64034;
	optional bool goproto_unkeyed = 64035;
}

extend google.protobuf.FieldOptions {
	optional bool nullable = 65001;
	optional bool embed = 65002;
	optional string customtype = 65003;
	optional string customname = 65004;
	optional string jsontag = 65005;
	optional string moretags = 65006;
	optional string casttype = 65007;
	optional string castkey = 65008;
	optional string castvalue = 65009;

	optional bool stdtime = 65010;
	optional bool stdduration = 65011;
	optional bool wktpointer = 65012;

}
]], "gogoproto/gogo.proto"))


assert(p:load([[
syntax = "proto3";
package mvccpb;

import "gogoproto/gogo.proto";

option go_package = "go.etcd.io/etcd/api/v3/mvccpb";

option (gogoproto.marshaler_all) = true;
option (gogoproto.sizer_all) = true;
option (gogoproto.unmarshaler_all) = true;
option (gogoproto.goproto_getters_all) = false;
option (gogoproto.goproto_enum_prefix_all) = false;

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

assert(p:load([[
syntax = "proto3";
package authpb;

import "gogoproto/gogo.proto";

option go_package = "go.etcd.io/etcd/api/v3/authpb";

option (gogoproto.marshaler_all) = true;
option (gogoproto.sizer_all) = true;
option (gogoproto.unmarshaler_all) = true;
option (gogoproto.goproto_getters_all) = false;
option (gogoproto.goproto_enum_prefix_all) = false;

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
}
]], "etcd/api/authpb/auth.proto"))

assert(p:load([[
syntax = "proto3";
package versionpb;

import "gogoproto/gogo.proto";
import "google/protobuf/descriptor.proto";

option go_package = "go.etcd.io/etcd/api/v3/versionpb";

option (gogoproto.marshaler_all) = true;
option (gogoproto.unmarshaler_all) = true;

// Indicates etcd version that introduced the message, used to determine minimal etcd version required to interpret wal that includes this message.
extend google.protobuf.MessageOptions {
  string etcd_version_msg = 50000;
}

// Indicates etcd version that introduced the field, used to determine minimal etcd version required to interpret wal that sets this field.
extend google.protobuf.FieldOptions {
  string etcd_version_field = 50001;
}

// Indicates etcd version that introduced the enum, used to determine minimal etcd version required to interpret wal that uses this enum.
extend google.protobuf.EnumOptions {
  string etcd_version_enum = 50002;
}

// Indicates etcd version that introduced the enum value, used to determine minimal etcd version required to interpret wal that sets this enum value.
extend google.protobuf.EnumValueOptions {
  string etcd_version_enum_value = 50003;
}
]], "etcd/api/versionpb/version.proto"))

assert(p:load([[
syntax = "proto3";
package etcdserverpb;

import "gogoproto/gogo.proto";
import "etcd/api/mvccpb/kv.proto";
import "etcd/api/authpb/auth.proto";
import "etcd/api/versionpb/version.proto";

option go_package = "go.etcd.io/etcd/api/v3/etcdserverpb";

option (gogoproto.marshaler_all) = true;
option (gogoproto.unmarshaler_all) = true;

service KV {
  // Range gets the keys in the range from the key-value store.
  rpc Range(RangeRequest) returns (RangeResponse) {
      option (google.api.http) = {
        post: "/v3/kv/range"
        body: "*"
    };
  }

  // Put puts the given key into the key-value store.
  // A put request increments the revision of the key-value store
  // and generates one event in the event history.
  rpc Put(PutRequest) returns (PutResponse) {
      option (google.api.http) = {
        post: "/v3/kv/put"
        body: "*"
    };
  }

  // DeleteRange deletes the given range from the key-value store.
  // A delete request increments the revision of the key-value store
  // and generates a delete event in the event history for every deleted key.
  rpc DeleteRange(DeleteRangeRequest) returns (DeleteRangeResponse) {
      option (google.api.http) = {
        post: "/v3/kv/deleterange"
        body: "*"
    };
  }

  // Txn processes multiple requests in a single transaction.
  // A txn request increments the revision of the key-value store
  // and generates events with the same revision for every completed request.
  // It is not allowed to modify the same key several times within one txn.
  rpc Txn(TxnRequest) returns (TxnResponse) {
      option (google.api.http) = {
        post: "/v3/kv/txn"
        body: "*"
    };
  }

  // Compact compacts the event history in the etcd key-value store. The key-value
  // store should be periodically compacted or the event history will continue to grow
  // indefinitely.
  rpc Compact(CompactionRequest) returns (CompactionResponse) {
      option (google.api.http) = {
        post: "/v3/kv/compaction"
        body: "*"
    };
  }
}

service Watch {
  // Watch watches for events happening or that have happened. Both input and output
  // are streams; the input stream is for creating and canceling watchers and the output
  // stream sends events. One watch RPC can watch on multiple key ranges, streaming events
  // for several watches at once. The entire event history can be watched starting from the
  // last compaction revision.
  rpc Watch(stream WatchRequest) returns (stream WatchResponse) {
      option (google.api.http) = {
        post: "/v3/watch"
        body: "*"
    };
  }
}

service Lease {
  // LeaseGrant creates a lease which expires if the server does not receive a keepAlive
  // within a given time to live period. All keys attached to the lease will be expired and
  // deleted if the lease expires. Each expired key generates a delete event in the event history.
  rpc LeaseGrant(LeaseGrantRequest) returns (LeaseGrantResponse) {
      option (google.api.http) = {
        post: "/v3/lease/grant"
        body: "*"
    };
  }

  // LeaseRevoke revokes a lease. All keys attached to the lease will expire and be deleted.
  rpc LeaseRevoke(LeaseRevokeRequest) returns (LeaseRevokeResponse) {
      option (google.api.http) = {
        post: "/v3/lease/revoke"
        body: "*"
        additional_bindings {
            post: "/v3/kv/lease/revoke"
            body: "*"
        }
    };
  }

  // LeaseKeepAlive keeps the lease alive by streaming keep alive requests from the client
  // to the server and streaming keep alive responses from the server to the client.
  rpc LeaseKeepAlive(stream LeaseKeepAliveRequest) returns (stream LeaseKeepAliveResponse) {
      option (google.api.http) = {
        post: "/v3/lease/keepalive"
        body: "*"
    };
  }

  // LeaseTimeToLive retrieves lease information.
  rpc LeaseTimeToLive(LeaseTimeToLiveRequest) returns (LeaseTimeToLiveResponse) {
      option (google.api.http) = {
        post: "/v3/lease/timetolive"
        body: "*"
        additional_bindings {
            post: "/v3/kv/lease/timetolive"
            body: "*"
        }
    };
  }

  // LeaseLeases lists all existing leases.
  rpc LeaseLeases(LeaseLeasesRequest) returns (LeaseLeasesResponse) {
      option (google.api.http) = {
        post: "/v3/lease/leases"
        body: "*"
        additional_bindings {
            post: "/v3/kv/lease/leases"
            body: "*"
        }
    };
  }
}

service Cluster {
  // MemberAdd adds a member into the cluster.
  rpc MemberAdd(MemberAddRequest) returns (MemberAddResponse) {
      option (google.api.http) = {
        post: "/v3/cluster/member/add"
        body: "*"
    };
  }

  // MemberRemove removes an existing member from the cluster.
  rpc MemberRemove(MemberRemoveRequest) returns (MemberRemoveResponse) {
      option (google.api.http) = {
        post: "/v3/cluster/member/remove"
        body: "*"
    };
  }

  // MemberUpdate updates the member configuration.
  rpc MemberUpdate(MemberUpdateRequest) returns (MemberUpdateResponse) {
      option (google.api.http) = {
        post: "/v3/cluster/member/update"
        body: "*"
    };
  }

  // MemberList lists all the members in the cluster.
  rpc MemberList(MemberListRequest) returns (MemberListResponse) {
      option (google.api.http) = {
        post: "/v3/cluster/member/list"
        body: "*"
    };
  }

  // MemberPromote promotes a member from raft learner (non-voting) to raft voting member.
  rpc MemberPromote(MemberPromoteRequest) returns (MemberPromoteResponse) {
      option (google.api.http) = {
        post: "/v3/cluster/member/promote"
        body: "*"
    };
  }
}

service Maintenance {
  // Alarm activates, deactivates, and queries alarms regarding cluster health.
  rpc Alarm(AlarmRequest) returns (AlarmResponse) {
      option (google.api.http) = {
        post: "/v3/maintenance/alarm"
        body: "*"
    };
  }

  // Status gets the status of the member.
  rpc Status(StatusRequest) returns (StatusResponse) {
      option (google.api.http) = {
        post: "/v3/maintenance/status"
        body: "*"
    };
  }

  // Defragment defragments a member's backend database to recover storage space.
  rpc Defragment(DefragmentRequest) returns (DefragmentResponse) {
      option (google.api.http) = {
        post: "/v3/maintenance/defragment"
        body: "*"
    };
  }

  // Hash computes the hash of whole backend keyspace,
  // including key, lease, and other buckets in storage.
  // This is designed for testing ONLY!
  // Do not rely on this in production with ongoing transactions,
  // since Hash operation does not hold MVCC locks.
  // Use "HashKV" API instead for "key" bucket consistency checks.
  rpc Hash(HashRequest) returns (HashResponse) {
      option (google.api.http) = {
        post: "/v3/maintenance/hash"
        body: "*"
    };
  }

  // HashKV computes the hash of all MVCC keys up to a given revision.
  // It only iterates "key" bucket in backend storage.
  rpc HashKV(HashKVRequest) returns (HashKVResponse) {
      option (google.api.http) = {
        post: "/v3/maintenance/hashkv"
        body: "*"
    };
  }

  // Snapshot sends a snapshot of the entire backend from a member over a stream to a client.
  rpc Snapshot(SnapshotRequest) returns (stream SnapshotResponse) {
      option (google.api.http) = {
        post: "/v3/maintenance/snapshot"
        body: "*"
    };
  }

  // MoveLeader requests current leader node to transfer its leadership to transferee.
  rpc MoveLeader(MoveLeaderRequest) returns (MoveLeaderResponse) {
      option (google.api.http) = {
        post: "/v3/maintenance/transfer-leadership"
        body: "*"
    };
  }

  // Downgrade requests downgrades, verifies feasibility or cancels downgrade
  // on the cluster version.
  // Supported since etcd 3.5.
  rpc Downgrade(DowngradeRequest) returns (DowngradeResponse) {
    option (google.api.http) = {
      post: "/v3/maintenance/downgrade"
      body: "*"
    };
  }
}

service Auth {
  // AuthEnable enables authentication.
  rpc AuthEnable(AuthEnableRequest) returns (AuthEnableResponse) {
      option (google.api.http) = {
        post: "/v3/auth/enable"
        body: "*"
    };
  }

  // AuthDisable disables authentication.
  rpc AuthDisable(AuthDisableRequest) returns (AuthDisableResponse) {
      option (google.api.http) = {
        post: "/v3/auth/disable"
        body: "*"
    };
  }

  // AuthStatus displays authentication status.
  rpc AuthStatus(AuthStatusRequest) returns (AuthStatusResponse) {
      option (google.api.http) = {
        post: "/v3/auth/status"
        body: "*"
    };
  }

  // Authenticate processes an authenticate request.
  rpc Authenticate(AuthenticateRequest) returns (AuthenticateResponse) {
      option (google.api.http) = {
        post: "/v3/auth/authenticate"
        body: "*"
    };
  }

  // UserAdd adds a new user. User name cannot be empty.
  rpc UserAdd(AuthUserAddRequest) returns (AuthUserAddResponse) {
      option (google.api.http) = {
        post: "/v3/auth/user/add"
        body: "*"
    };
  }

  // UserGet gets detailed user information.
  rpc UserGet(AuthUserGetRequest) returns (AuthUserGetResponse) {
      option (google.api.http) = {
        post: "/v3/auth/user/get"
        body: "*"
    };
  }

  // UserList gets a list of all users.
  rpc UserList(AuthUserListRequest) returns (AuthUserListResponse) {
      option (google.api.http) = {
        post: "/v3/auth/user/list"
        body: "*"
    };
  }

  // UserDelete deletes a specified user.
  rpc UserDelete(AuthUserDeleteRequest) returns (AuthUserDeleteResponse) {
      option (google.api.http) = {
        post: "/v3/auth/user/delete"
        body: "*"
    };
  }

  // UserChangePassword changes the password of a specified user.
  rpc UserChangePassword(AuthUserChangePasswordRequest) returns (AuthUserChangePasswordResponse) {
      option (google.api.http) = {
        post: "/v3/auth/user/changepw"
        body: "*"
    };
  }

  // UserGrant grants a role to a specified user.
  rpc UserGrantRole(AuthUserGrantRoleRequest) returns (AuthUserGrantRoleResponse) {
      option (google.api.http) = {
        post: "/v3/auth/user/grant"
        body: "*"
    };
  }

  // UserRevokeRole revokes a role of specified user.
  rpc UserRevokeRole(AuthUserRevokeRoleRequest) returns (AuthUserRevokeRoleResponse) {
      option (google.api.http) = {
        post: "/v3/auth/user/revoke"
        body: "*"
    };
  }

  // RoleAdd adds a new role. Role name cannot be empty.
  rpc RoleAdd(AuthRoleAddRequest) returns (AuthRoleAddResponse) {
      option (google.api.http) = {
        post: "/v3/auth/role/add"
        body: "*"
    };
  }

  // RoleGet gets detailed role information.
  rpc RoleGet(AuthRoleGetRequest) returns (AuthRoleGetResponse) {
      option (google.api.http) = {
        post: "/v3/auth/role/get"
        body: "*"
    };
  }

  // RoleList gets lists of all roles.
  rpc RoleList(AuthRoleListRequest) returns (AuthRoleListResponse) {
      option (google.api.http) = {
        post: "/v3/auth/role/list"
        body: "*"
    };
  }

  // RoleDelete deletes a specified role.
  rpc RoleDelete(AuthRoleDeleteRequest) returns (AuthRoleDeleteResponse) {
      option (google.api.http) = {
        post: "/v3/auth/role/delete"
        body: "*"
    };
  }

  // RoleGrantPermission grants a permission of a specified key or range to a specified role.
  rpc RoleGrantPermission(AuthRoleGrantPermissionRequest) returns (AuthRoleGrantPermissionResponse) {
      option (google.api.http) = {
        post: "/v3/auth/role/grant"
        body: "*"
    };
  }

  // RoleRevokePermission revokes a key or range permission of a specified role.
  rpc RoleRevokePermission(AuthRoleRevokePermissionRequest) returns (AuthRoleRevokePermissionResponse) {
      option (google.api.http) = {
        post: "/v3/auth/role/revoke"
        body: "*"
    };
  }
}

message ResponseHeader {
  option (versionpb.etcd_version_msg) = "3.0";

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
  option (versionpb.etcd_version_msg) = "3.0";

  enum SortOrder {
    option (versionpb.etcd_version_enum) = "3.0";
    NONE = 0; // default, no sorting
    ASCEND = 1; // lowest target value first
    DESCEND = 2; // highest target value first
  }
  enum SortTarget {
    option (versionpb.etcd_version_enum) = "3.0";
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
  option (versionpb.etcd_version_msg) = "3.0";

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
  option (versionpb.etcd_version_msg) = "3.0";

  // key is the key, in bytes, to put into the key-value store.
  bytes key = 1;
  // value is the value, in bytes, to associate with the key in the key-value store.
  bytes value = 2;
  // lease is the lease ID to associate with the key in the key-value store. A lease
  // value of 0 indicates no lease.
  int64 lease = 3;

  // If prev_kv is set, etcd gets the previous key-value pair before changing it.
  // The previous key-value pair will be returned in the put response.
  bool prev_kv = 4 [(versionpb.etcd_version_field)="3.1"];

  // If ignore_value is set, etcd updates the key using its current value.
  // Returns an error if the key does not exist.
  bool ignore_value = 5 [(versionpb.etcd_version_field)="3.2"];

  // If ignore_lease is set, etcd updates the key using its current lease.
  // Returns an error if the key does not exist.
  bool ignore_lease = 6 [(versionpb.etcd_version_field)="3.2"];
}

message PutResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // if prev_kv is set in the request, the previous key-value pair will be returned.
  mvccpb.KeyValue prev_kv = 2 [(versionpb.etcd_version_field)="3.1"];
}

message DeleteRangeRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // key is the first key to delete in the range.
  bytes key = 1;
  // range_end is the key following the last key to delete for the range [key, range_end).
  // If range_end is not given, the range is defined to contain only the key argument.
  // If range_end is one bit larger than the given key, then the range is all the keys
  // with the prefix (the given key).
  // If range_end is '\0', the range is all keys greater than or equal to the key argument.
  bytes range_end = 2;

  // If prev_kv is set, etcd gets the previous key-value pairs before deleting it.
  // The previous key-value pairs will be returned in the delete response.
  bool prev_kv = 3 [(versionpb.etcd_version_field)="3.1"];
}

message DeleteRangeResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // deleted is the number of keys deleted by the delete range request.
  int64 deleted = 2;
  // if prev_kv is set in the request, the previous key-value pairs will be returned.
  repeated mvccpb.KeyValue prev_kvs = 3 [(versionpb.etcd_version_field)="3.1"];
}

message RequestOp {
  option (versionpb.etcd_version_msg) = "3.0";
  // request is a union of request types accepted by a transaction.
  oneof request {
    RangeRequest request_range = 1;
    PutRequest request_put = 2;
    DeleteRangeRequest request_delete_range = 3;
    TxnRequest request_txn = 4 [(versionpb.etcd_version_field)="3.3"];
  }
}

message ResponseOp {
  option (versionpb.etcd_version_msg) = "3.0";

  // response is a union of response types returned by a transaction.
  oneof response {
    RangeResponse response_range = 1;
    PutResponse response_put = 2;
    DeleteRangeResponse response_delete_range = 3;
    TxnResponse response_txn = 4 [(versionpb.etcd_version_field)="3.3"];
  }
}

message Compare {
  option (versionpb.etcd_version_msg) = "3.0";

  enum CompareResult {
    option (versionpb.etcd_version_enum) = "3.0";

    EQUAL = 0;
    GREATER = 1;
    LESS = 2;
    NOT_EQUAL = 3 [(versionpb.etcd_version_enum_value)="3.1"];
  }
  enum CompareTarget {
    option (versionpb.etcd_version_enum) = "3.0";

    VERSION = 0;
    CREATE = 1;
    MOD = 2;
    VALUE = 3;
    LEASE = 4 [(versionpb.etcd_version_enum_value)="3.3"];
  }
  // result is logical comparison operation for this comparison.
  CompareResult result = 1;
  // target is the key-value field to inspect for the comparison.
  CompareTarget target = 2;
  // key is the subject key for the comparison operation.
  bytes key = 3;
  oneof target_union {
    // version is the version of the given key
    int64 version = 4;
    // create_revision is the creation revision of the given key
    int64 create_revision = 5;
    // mod_revision is the last modified revision of the given key.
    int64 mod_revision = 6;
    // value is the value of the given key, in bytes.
    bytes value = 7;
    // lease is the lease id of the given key.
    int64 lease = 8 [(versionpb.etcd_version_field)="3.3"];
    // leave room for more target_union field tags, jump to 64
  }

  // range_end compares the given target to all keys in the range [key, range_end).
  // See RangeRequest for more details on key ranges.
  bytes range_end = 64 [(versionpb.etcd_version_field)="3.3"];
  // TODO: fill out with most of the rest of RangeRequest fields when needed.
}

// From google paxosdb paper:
// Our implementation hinges around a powerful primitive which we call MultiOp. All other database
// operations except for iteration are implemented as a single call to MultiOp. A MultiOp is applied atomically
// and consists of three components:
// 1. A list of tests called guard. Each test in guard checks a single entry in the database. It may check
// for the absence or presence of a value, or compare with a given value. Two different tests in the guard
// may apply to the same or different entries in the database. All tests in the guard are applied and
// MultiOp returns the results. If all tests are true, MultiOp executes t op (see item 2 below), otherwise
// it executes f op (see item 3 below).
// 2. A list of database operations called t op. Each operation in the list is either an insert, delete, or
// lookup operation, and applies to a single database entry. Two different operations in the list may apply
// to the same or different entries in the database. These operations are executed
// if guard evaluates to
// true.
// 3. A list of database operations called f op. Like t op, but executed if guard evaluates to false.
message TxnRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // compare is a list of predicates representing a conjunction of terms.
  // If the comparisons succeed, then the success requests will be processed in order,
  // and the response will contain their respective responses in order.
  // If the comparisons fail, then the failure requests will be processed in order,
  // and the response will contain their respective responses in order.
  repeated Compare compare = 1;
  // success is a list of requests which will be applied when compare evaluates to true.
  repeated RequestOp success = 2;
  // failure is a list of requests which will be applied when compare evaluates to false.
  repeated RequestOp failure = 3;
}

message TxnResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // succeeded is set to true if the compare evaluated to true or false otherwise.
  bool succeeded = 2;
  // responses is a list of responses corresponding to the results from applying
  // success if succeeded is true or failure if succeeded is false.
  repeated ResponseOp responses = 3;
}

// CompactionRequest compacts the key-value store up to a given revision. All superseded keys
// with a revision less than the compaction revision will be removed.
message CompactionRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // revision is the key-value store revision for the compaction operation.
  int64 revision = 1;
  // physical is set so the RPC will wait until the compaction is physically
  // applied to the local database such that compacted entries are totally
  // removed from the backend database.
  bool physical = 2;
}

message CompactionResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message HashRequest {
  option (versionpb.etcd_version_msg) = "3.0";
}

message HashKVRequest {
  option (versionpb.etcd_version_msg) = "3.3";
  // revision is the key-value store revision for the hash operation.
  int64 revision = 1;
}

message HashKVResponse {
  option (versionpb.etcd_version_msg) = "3.3";

  ResponseHeader header = 1;
  // hash is the hash value computed from the responding member's MVCC keys up to a given revision.
  uint32 hash = 2;
  // compact_revision is the compacted revision of key-value store when hash begins.
  int64 compact_revision = 3;
  // hash_revision is the revision up to which the hash is calculated.
  int64 hash_revision = 4 [(versionpb.etcd_version_field)="3.6"];
}

message HashResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // hash is the hash value computed from the responding member's KV's backend.
  uint32 hash = 2;
}

message SnapshotRequest {
  option (versionpb.etcd_version_msg) = "3.3";
}

message SnapshotResponse {
  option (versionpb.etcd_version_msg) = "3.3";

  // header has the current key-value store information. The first header in the snapshot
  // stream indicates the point in time of the snapshot.
  ResponseHeader header = 1;

  // remaining_bytes is the number of blob bytes to be sent after this message
  uint64 remaining_bytes = 2;

  // blob contains the next chunk of the snapshot in the snapshot stream.
  bytes blob = 3;

  // local version of server that created the snapshot.
  // In cluster with binaries with different version, each cluster can return different result.
  // Informs which etcd server version should be used when restoring the snapshot.
  string version = 4 [(versionpb.etcd_version_field)="3.6"];
}

message WatchRequest {
  option (versionpb.etcd_version_msg) = "3.0";
  // request_union is a request to either create a new watcher or cancel an existing watcher.
  oneof request_union {
    WatchCreateRequest create_request = 1;
    WatchCancelRequest cancel_request = 2;
    WatchProgressRequest progress_request = 3 [(versionpb.etcd_version_field)="3.4"];
  }
}

message WatchCreateRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // key is the key to register for watching.
  bytes key = 1;

  // range_end is the end of the range [key, range_end) to watch. If range_end is not given,
  // only the key argument is watched. If range_end is equal to '\0', all keys greater than
  // or equal to the key argument are watched.
  // If the range_end is one bit larger than the given key,
  // then all keys with the prefix (the given key) will be watched.
  bytes range_end = 2;

  // start_revision is an optional revision to watch from (inclusive). No start_revision is "now".
  int64 start_revision = 3;

  // progress_notify is set so that the etcd server will periodically send a WatchResponse with
  // no events to the new watcher if there are no recent events. It is useful when clients
  // wish to recover a disconnected watcher starting from a recent known revision.
  // The etcd server may decide how often it will send notifications based on current load.
  bool progress_notify = 4;

  enum FilterType {
    option (versionpb.etcd_version_enum) = "3.1";

    // filter out put event.
    NOPUT = 0;
    // filter out delete event.
    NODELETE = 1;
  }

  // filters filter the events at server side before it sends back to the watcher.
  repeated FilterType filters = 5 [(versionpb.etcd_version_field)="3.1"];

  // If prev_kv is set, created watcher gets the previous KV before the event happens.
  // If the previous KV is already compacted, nothing will be returned.
  bool prev_kv = 6 [(versionpb.etcd_version_field)="3.1"];

  // If watch_id is provided and non-zero, it will be assigned to this watcher.
  // Since creating a watcher in etcd is not a synchronous operation,
  // this can be used ensure that ordering is correct when creating multiple
  // watchers on the same stream. Creating a watcher with an ID already in
  // use on the stream will cause an error to be returned.
  int64 watch_id = 7 [(versionpb.etcd_version_field)="3.4"];

  // fragment enables splitting large revisions into multiple watch responses.
  bool fragment = 8 [(versionpb.etcd_version_field)="3.4"];
}

message WatchCancelRequest {
  option (versionpb.etcd_version_msg) = "3.1";
  // watch_id is the watcher id to cancel so that no more events are transmitted.
  int64 watch_id = 1 [(versionpb.etcd_version_field)="3.1"];
}

// Requests the a watch stream progress status be sent in the watch response stream as soon as
// possible.
message WatchProgressRequest {
  option (versionpb.etcd_version_msg) = "3.4";
}

message WatchResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // watch_id is the ID of the watcher that corresponds to the response.
  int64 watch_id = 2;

  // created is set to true if the response is for a create watch request.
  // The client should record the watch_id and expect to receive events for
  // the created watcher from the same stream.
  // All events sent to the created watcher will attach with the same watch_id.
  bool created = 3;

  // canceled is set to true if the response is for a cancel watch request.
  // No further events will be sent to the canceled watcher.
  bool canceled = 4;

  // compact_revision is set to the minimum index if a watcher tries to watch
  // at a compacted index.
  //
  // This happens when creating a watcher at a compacted revision or the watcher cannot
  // catch up with the progress of the key-value store.
  //
  // The client should treat the watcher as canceled and should not try to create any
  // watcher with the same start_revision again.
  int64 compact_revision = 5;

  // cancel_reason indicates the reason for canceling the watcher.
  string cancel_reason = 6 [(versionpb.etcd_version_field)="3.4"];

  // framgment is true if large watch response was split over multiple responses.
  bool fragment = 7 [(versionpb.etcd_version_field)="3.4"];

  repeated mvccpb.Event events = 11;
}

message LeaseGrantRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // TTL is the advisory time-to-live in seconds. Expired lease will return -1.
  int64 TTL = 1;
  // ID is the requested ID for the lease. If ID is set to 0, the lessor chooses an ID.
  int64 ID = 2;
}

message LeaseGrantResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // ID is the lease ID for the granted lease.
  int64 ID = 2;
  // TTL is the server chosen lease time-to-live in seconds.
  int64 TTL = 3;
  string error = 4;
}

message LeaseRevokeRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // ID is the lease ID to revoke. When the ID is revoked, all associated keys will be deleted.
  int64 ID = 1;
}

message LeaseRevokeResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message LeaseCheckpoint {
  option (versionpb.etcd_version_msg) = "3.4";

    // ID is the lease ID to checkpoint.
  int64 ID = 1;

  // Remaining_TTL is the remaining time until expiry of the lease.
  int64 remaining_TTL = 2;
}

message LeaseCheckpointRequest {
  option (versionpb.etcd_version_msg) = "3.4";

  repeated LeaseCheckpoint checkpoints = 1;
}

message LeaseCheckpointResponse {
  option (versionpb.etcd_version_msg) = "3.4";

  ResponseHeader header = 1;
}

message LeaseKeepAliveRequest {
  option (versionpb.etcd_version_msg) = "3.0";
  // ID is the lease ID for the lease to keep alive.
  int64 ID = 1;
}

message LeaseKeepAliveResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // ID is the lease ID from the keep alive request.
  int64 ID = 2;
  // TTL is the new time-to-live for the lease.
  int64 TTL = 3;
}

message LeaseTimeToLiveRequest {
  option (versionpb.etcd_version_msg) = "3.1";
  // ID is the lease ID for the lease.
  int64 ID = 1;
  // keys is true to query all the keys attached to this lease.
  bool keys = 2;
}

message LeaseTimeToLiveResponse {
  option (versionpb.etcd_version_msg) = "3.1";

  ResponseHeader header = 1;
  // ID is the lease ID from the keep alive request.
  int64 ID = 2;
  // TTL is the remaining TTL in seconds for the lease; the lease will expire in under TTL+1 seconds.
  int64 TTL = 3;
  // GrantedTTL is the initial granted time in seconds upon lease creation/renewal.
  int64 grantedTTL = 4;
  // Keys is the list of keys attached to this lease.
  repeated bytes keys = 5;
}

message LeaseLeasesRequest {
  option (versionpb.etcd_version_msg) = "3.3";
}

message LeaseStatus {
  option (versionpb.etcd_version_msg) = "3.3";

  int64 ID = 1;
  // TODO: int64 TTL = 2;
}

message LeaseLeasesResponse {
  option (versionpb.etcd_version_msg) = "3.3";

  ResponseHeader header = 1;
  repeated LeaseStatus leases = 2;
}

message Member {
  option (versionpb.etcd_version_msg) = "3.0";

  // ID is the member ID for this member.
  uint64 ID = 1;
  // name is the human-readable name of the member. If the member is not started, the name will be an empty string.
  string name = 2;
  // peerURLs is the list of URLs the member exposes to the cluster for communication.
  repeated string peerURLs = 3;
  // clientURLs is the list of URLs the member exposes to clients for communication. If the member is not started, clientURLs will be empty.
  repeated string clientURLs = 4;
  // isLearner indicates if the member is raft learner.
  bool isLearner = 5 [(versionpb.etcd_version_field)="3.4"];
}

message MemberAddRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // peerURLs is the list of URLs the added member will use to communicate with the cluster.
  repeated string peerURLs = 1;
  // isLearner indicates if the added member is raft learner.
  bool isLearner = 2 [(versionpb.etcd_version_field)="3.4"];
}

message MemberAddResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // member is the member information for the added member.
  Member member = 2;
  // members is a list of all members after adding the new member.
  repeated Member members = 3;
}

message MemberRemoveRequest {
  option (versionpb.etcd_version_msg) = "3.0";
  // ID is the member ID of the member to remove.
  uint64 ID = 1;
}

message MemberRemoveResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // members is a list of all members after removing the member.
  repeated Member members = 2;
}

message MemberUpdateRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // ID is the member ID of the member to update.
  uint64 ID = 1;
  // peerURLs is the new list of URLs the member will use to communicate with the cluster.
  repeated string peerURLs = 2;
}

message MemberUpdateResponse{
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // members is a list of all members after updating the member.
  repeated Member members = 2 [(versionpb.etcd_version_field)="3.1"];
}

message MemberListRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  bool linearizable = 1 [(versionpb.etcd_version_field)="3.5"];
}

message MemberListResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // members is a list of all members associated with the cluster.
  repeated Member members = 2;
}

message MemberPromoteRequest {
  option (versionpb.etcd_version_msg) = "3.4";
  // ID is the member ID of the member to promote.
  uint64 ID = 1;
}

message MemberPromoteResponse {
  option (versionpb.etcd_version_msg) = "3.4";

  ResponseHeader header = 1;
  // members is a list of all members after promoting the member.
  repeated Member members = 2;
}

message DefragmentRequest {
  option (versionpb.etcd_version_msg) = "3.0";
}

message DefragmentResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message MoveLeaderRequest {
  option (versionpb.etcd_version_msg) = "3.3";
  // targetID is the node ID for the new leader.
  uint64 targetID = 1;
}

message MoveLeaderResponse {
  option (versionpb.etcd_version_msg) = "3.3";

  ResponseHeader header = 1;
}

enum AlarmType {
  option (versionpb.etcd_version_enum) = "3.0";

	NONE = 0; // default, used to query if any alarm is active
	NOSPACE = 1; // space quota is exhausted
	CORRUPT = 2 [(versionpb.etcd_version_enum_value)="3.3"]; // kv store corruption detected
}

message AlarmRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  enum AlarmAction {
    option (versionpb.etcd_version_enum) = "3.0";

    GET = 0;
    ACTIVATE = 1;
    DEACTIVATE = 2;
  }
  // action is the kind of alarm request to issue. The action
  // may GET alarm statuses, ACTIVATE an alarm, or DEACTIVATE a
  // raised alarm.
  AlarmAction action = 1;
  // memberID is the ID of the member associated with the alarm. If memberID is 0, the
  // alarm request covers all members.
  uint64 memberID = 2;
  // alarm is the type of alarm to consider for this request.
  AlarmType alarm = 3;
}

message AlarmMember {
  option (versionpb.etcd_version_msg) = "3.0";
  // memberID is the ID of the member associated with the raised alarm.
  uint64 memberID = 1;
  // alarm is the type of alarm which has been raised.
  AlarmType alarm = 2;
}

message AlarmResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // alarms is a list of alarms associated with the alarm request.
  repeated AlarmMember alarms = 2;
}

message DowngradeRequest {
  option (versionpb.etcd_version_msg) = "3.5";

  enum DowngradeAction {
    option (versionpb.etcd_version_enum) = "3.5";

    VALIDATE = 0;
    ENABLE = 1;
    CANCEL = 2;
  }

  // action is the kind of downgrade request to issue. The action may
  // VALIDATE the target version, DOWNGRADE the cluster version,
  // or CANCEL the current downgrading job.
  DowngradeAction action = 1;
  // version is the target version to downgrade.
  string version = 2;
}

message DowngradeResponse {
  option (versionpb.etcd_version_msg) = "3.5";

  ResponseHeader header = 1;
  // version is the current cluster version.
  string version = 2;
}

message StatusRequest {
  option (versionpb.etcd_version_msg) = "3.0";
}

message StatusResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // version is the cluster protocol version used by the responding member.
  string version = 2;
  // dbSize is the size of the backend database physically allocated, in bytes, of the responding member.
  int64 dbSize = 3;
  // leader is the member ID which the responding member believes is the current leader.
  uint64 leader = 4;
  // raftIndex is the current raft committed index of the responding member.
  uint64 raftIndex = 5;
  // raftTerm is the current raft term of the responding member.
  uint64 raftTerm = 6;
  // raftAppliedIndex is the current raft applied index of the responding member.
  uint64 raftAppliedIndex = 7 [(versionpb.etcd_version_field)="3.4"];
  // errors contains alarm/health information and status.
  repeated string errors = 8 [(versionpb.etcd_version_field)="3.4"];
  // dbSizeInUse is the size of the backend database logically in use, in bytes, of the responding member.
  int64 dbSizeInUse = 9 [(versionpb.etcd_version_field)="3.4"];
  // isLearner indicates if the member is raft learner.
  bool isLearner = 10 [(versionpb.etcd_version_field)="3.4"];
  // storageVersion is the version of the db file. It might be get updated with delay in relationship to the target cluster version.
  string storageVersion = 11 [(versionpb.etcd_version_field)="3.6"];
}

message AuthEnableRequest {
  option (versionpb.etcd_version_msg) = "3.0";
}

message AuthDisableRequest {
  option (versionpb.etcd_version_msg) = "3.0";
}

message AuthStatusRequest {
  option (versionpb.etcd_version_msg) = "3.5";
}

message AuthenticateRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  string name = 1;
  string password = 2;
}

message AuthUserAddRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  string name = 1;
  string password = 2;
  authpb.UserAddOptions options = 3 [(versionpb.etcd_version_field)="3.4"];
  string hashedPassword = 4 [(versionpb.etcd_version_field)="3.5"];
}

message AuthUserGetRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  string name = 1;
}

message AuthUserDeleteRequest {
  option (versionpb.etcd_version_msg) = "3.0";
  // name is the name of the user to delete.
  string name = 1;
}

message AuthUserChangePasswordRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // name is the name of the user whose password is being changed.
  string name = 1;
  // password is the new password for the user. Note that this field will be removed in the API layer.
  string password = 2;
  // hashedPassword is the new password for the user. Note that this field will be initialized in the API layer.
  string hashedPassword = 3 [(versionpb.etcd_version_field)="3.5"];
}

message AuthUserGrantRoleRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // user is the name of the user which should be granted a given role.
  string user = 1;
  // role is the name of the role to grant to the user.
  string role = 2;
}

message AuthUserRevokeRoleRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  string name = 1;
  string role = 2;
}

message AuthRoleAddRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // name is the name of the role to add to the authentication system.
  string name = 1;
}

message AuthRoleGetRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  string role = 1;
}

message AuthUserListRequest {
  option (versionpb.etcd_version_msg) = "3.0";
}

message AuthRoleListRequest {
  option (versionpb.etcd_version_msg) = "3.0";
}

message AuthRoleDeleteRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  string role = 1;
}

message AuthRoleGrantPermissionRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  // name is the name of the role which will be granted the permission.
  string name = 1;
  // perm is the permission to grant to the role.
  authpb.Permission perm = 2;
}

message AuthRoleRevokePermissionRequest {
  option (versionpb.etcd_version_msg) = "3.0";

  string role = 1;
  bytes key = 2;
  bytes range_end = 3;
}

message AuthEnableResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthDisableResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthStatusResponse {
  option (versionpb.etcd_version_msg) = "3.5";

  ResponseHeader header = 1;
  bool enabled = 2;
  // authRevision is the current revision of auth store
  uint64 authRevision = 3;
}

message AuthenticateResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
  // token is an authorized token that can be used in succeeding RPCs
  string token = 2;
}

message AuthUserAddResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthUserGetResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;

  repeated string roles = 2;
}

message AuthUserDeleteResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthUserChangePasswordResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthUserGrantRoleResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthUserRevokeRoleResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthRoleAddResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthRoleGetResponse {
  ResponseHeader header = 1 [(versionpb.etcd_version_field)="3.0"];

  repeated authpb.Permission perm = 2 [(versionpb.etcd_version_field)="3.0"];
}

message AuthRoleListResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;

  repeated string roles = 2;
}

message AuthUserListResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;

  repeated string users = 2;
}

message AuthRoleDeleteResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthRoleGrantPermissionResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}

message AuthRoleRevokePermissionResponse {
  option (versionpb.etcd_version_msg) = "3.0";

  ResponseHeader header = 1;
}
]], "etcdv3.proto"))

---@class silly.store.etcd.ResponseHeader
---@field cluster_id integer
---@field member_id integer
---@field revision integer
---@field raft_term integer

---@class silly.store.etcd.KeyValue
---@field key string
---@field create_revision integer
---@field mod_revision integer
---@field version integer
---@field value string
---@field lease integer

---@class silly.store.etcd.Event
---@field type integer
---@field kv silly.store.etcd.KeyValue
---@field prev_kv silly.store.etcd.KeyValue


---@class silly.store.etcd.LeaseKeepAliveResponse
---@field header silly.store.etcd.ResponseHeader
---@field ID integer
---@field TTL integer

---@class silly.store.etcd.WatchCreateRequest
---@field key string
---@field range_end string?
---@field start_revision integer?
---@field progress_notify boolean?
---@field filters silly.store.etcd.WatchFilterType[]?
---@field prev_kv boolean?
---@field watch_id integer
---@field fragment boolean?

---@class silly.store.etcd.WatchCancelRequest
---@field watch_id integer

---@class silly.store.etcd.WatchProgressRequest
---@field progress_request boolean

---@class silly.store.etcd.WatchRequest
---@field create_request silly.store.etcd.WatchCreateRequest?
---@field cancel_request silly.store.etcd.WatchCancelRequest?
---@field progress_request silly.store.etcd.WatchProgressRequest?

---@class silly.store.etcd.WatchResponse
---@field header silly.store.etcd.ResponseHeader
---@field watch_id integer
---@field created boolean
---@field canceled boolean
---@field compact_revision integer
---@field cancel_reason string
---@field fragment boolean
---@field events silly.store.etcd.Event[]

return p