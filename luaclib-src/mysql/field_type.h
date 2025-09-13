#ifndef __MYSQL_FIELD_H__
#define __MYSQL_FIELD_H__

// https://mariadb.com/kb/en/result-set-packets/#column-definition-packet

#define MYSQL_TYPE_DECIMAL 0 // byte<lenenc> encoding
#define MYSQL_TYPE_TINY 1    // TINYINT Binary encoding
#define MYSQL_TYPE_SHORT 2   // SMALLINT Binary encoding
#define MYSQL_TYPE_LONG 3    // INTEGER Binary encoding
#define MYSQL_TYPE_FLOAT 4   // FLOAT Binary encoding
#define MYSQL_TYPE_DOUBLE 5  // DOUBLE Binary encoding
#define MYSQL_TYPE_NULL \
	6 // Not used, nullness is indicated by the NULL-bitmap in the result
#define MYSQL_TYPE_TIMESTAMP 7   // TIMESTAMP Binary encoding
#define MYSQL_TYPE_LONGLONG 8    // BIGINT Binary encoding
#define MYSQL_TYPE_INT24 9       // INTEGER Binary encoding
#define MYSQL_TYPE_DATE 10       // TIMESTAMP Binary encoding
#define MYSQL_TYPE_TIME 11       // TIME Binary encoding
#define MYSQL_TYPE_DATETIME 12   // TIMESTAMP Binary encoding
#define MYSQL_TYPE_YEAR 13       // SMALLINT Binary encoding
#define MYSQL_TYPE_NEWDATE 14    // byte<lenenc> encoding
#define MYSQL_TYPE_VARCHAR 15    // byte<lenenc> encoding
#define MYSQL_TYPE_BIT 16        // byte<lenenc> encoding
#define MYSQL_TYPE_JSON \
	245 // byte<lenenc> encoding (only used with MySQL, MariaDB uses MYSQL_TYPE_STRING for JSON)
#define MYSQL_TYPE_NEWDECIMAL 246  // byte<lenenc> encoding
#define MYSQL_TYPE_ENUM 247        // byte<lenenc> encoding
#define MYSQL_TYPE_SET 248         // byte<lenenc> encoding
#define MYSQL_TYPE_TINY_BLOB 249   // byte<lenenc> encoding
#define MYSQL_TYPE_MEDIUM_BLOB 250 // byte<lenenc> encoding
#define MYSQL_TYPE_LONG_BLOB 251   // byte<lenenc> encoding
#define MYSQL_TYPE_BLOB 252        // byte<lenenc> encoding
#define MYSQL_TYPE_VAR_STRING 253  // byte<lenenc> encoding
#define MYSQL_TYPE_STRING 254      // byte<lenenc> encoding
#define MYSQL_TYPE_GEOMETRY 255    // byte<lenenc> encoding

#define FIELD_FLAG_UNSIGNED 0x20


#endif
